/*
 * Ace 2 Pro (SM8550 / 5.15) Wondertap provider
 * Adapted from SM8850 donor for non-MLO hdd_adapter (vdev_id on adapter).
 * SPDX-License-Identifier: ISC
 */
#include <wlan_hdd_wondertap.h>
#include <wlan_hdd_main.h>
#include <wlan_hdd_tx_rx.h>
#include <wlan_hdd_rx_monitor.h>
#include <osif_psoc_sync.h>
#include <osif_vdev_sync.h>
#include <wlan_hdd_power.h>
#include <wlan_hdd_object_manager.h>
#include <wlan_hdd_packet_filter_api.h>
#include <wlan_vdev_mgr_api.h>
#include <wma_api.h>
#include <pld_common.h>
#include "cds_api.h"
#include "sme_api.h"
#include "wlan_policy_mgr_api.h"
#include "wlan_mlme_ucfg_api.h"
#include "wlan_hdd_regulatory.h"
#include <qdf_status.h>
#include <linux/random.h>
#include <linux/netdevice.h>
#include <linux/module.h>
#include <linux/rtnetlink.h>

#ifndef WIFI_POWER_EVENT_WAKELOCK_DRIVER_MIN
#define WIFI_POWER_EVENT_WAKELOCK_DRIVER_MIN 0
#endif

static struct hdd_wondertap_context *g_wt_ctx;

/*
 * soft_init=1 (default for Ace2 debug): allocate handle only, do NOT open
 * MONITOR/PASSTHRU adapter. Avoids mon-session hard-reset while Soft-MAC
 * + nl80211 cache path is validated. Set soft_init=0 after mon-session is fixed.
 */
static int soft_init = 1;
module_param(soft_init, int, 0644);
MODULE_PARM_DESC(soft_init,
		 "1=stub wondertap init (no mon session); 0=full adapter path");

static inline uint8_t wt_vdev_id(struct hdd_adapter *adapter)
{
	return adapter->vdev_id;
}

static enum phy_ch_width
wt_bw_to_phy(enum wondertap_rate_bw bw)
{
	switch (bw) {
	case WONDERTAP_RATE_BW_20:
		return CH_WIDTH_20MHZ;
	case WONDERTAP_RATE_BW_40:
		return CH_WIDTH_40MHZ;
	case WONDERTAP_RATE_BW_80:
		return CH_WIDTH_80MHZ;
	case WONDERTAP_RATE_BW_160:
		return CH_WIDTH_160MHZ;
	default:
		return CH_WIDTH_20MHZ;
	}
}

static enum hw_mode_bandwidth
wt_bw_to_hw(enum wondertap_rate_bw bw)
{
	switch (bw) {
	case WONDERTAP_RATE_BW_20:
		return HW_MODE_20_MHZ;
	case WONDERTAP_RATE_BW_40:
		return HW_MODE_40_MHZ;
	case WONDERTAP_RATE_BW_80:
		return HW_MODE_80_MHZ;
	case WONDERTAP_RATE_BW_160:
		return HW_MODE_160_MHZ;
	default:
		return HW_MODE_20_MHZ;
	}
}

static QDF_STATUS
wt_set_channel(struct hdd_context *hdd_ctx, struct hdd_adapter *adapter,
	       const struct wondertap_set_freq_params *params)
{
	enum phy_ch_width ch_width;
	int ret;

	(void)hdd_ctx;
	/*
	 * Ace2 monitor channel path completes on adapter->qdf_monitor_mode_vdev_up_event
	 * via hdd_sme_monitor_mode_callback — NOT g_wt_ctx->wondertap_vdev_event
	 * (passthrough callback). Reuse the stock helper.
	 */
	ch_width = wt_bw_to_phy(params->bandwidth);
	ret = wlan_hdd_set_mon_chan(adapter, params->freq, ch_width);
	if (ret) {
		hdd_err("wlan_hdd_set_mon_chan freq=%u bw=%d failed %d",
			params->freq, ch_width, ret);
		return qdf_status_from_os_return(ret);
	}
	return QDF_STATUS_SUCCESS;
}

static int
wt_set_fixed_tx_rate(struct hdd_adapter *adapter,
		     const struct wondertap_fixed_tx_rate_params *params)
{
	WMI_RATE_PREAMBLE preamble;
	uint32_t rate_code;
	uint8_t gi = 0;
	int ret;

	switch (params->preamble) {
	case WONDERTAP_RATE_PREAMBLE_HT:
		preamble = WMI_RATE_PREAMBLE_HT;
		break;
	case WONDERTAP_RATE_PREAMBLE_VHT:
		preamble = WMI_RATE_PREAMBLE_VHT;
		break;
	case WONDERTAP_RATE_PREAMBLE_HE:
		preamble = WMI_RATE_PREAMBLE_HE;
		break;
	default:
		preamble = WMI_RATE_PREAMBLE_CCK;
		break;
	}

	rate_code = hdd_assemble_rate_code(preamble, params->nss ? params->nss - 1 : 0,
					   params->mcs);
	ret = wma_cli_set_command(wt_vdev_id(adapter), wmi_vdev_param_fixed_rate,
				  rate_code, VDEV_CMD);
	if (ret)
		hdd_err("fixed rate failed:%d", ret);

	if (params->gi == WONDERTAP_RATE_GI_SHORT)
		gi = 1;
	else if (params->gi == WONDERTAP_RATE_GI_1_6_US)
		gi = 2;
	else if (params->gi == WONDERTAP_RATE_GI_3_2_US)
		gi = 3;

	ret = wma_cli_set_command(wt_vdev_id(adapter), wmi_vdev_param_sgi, gi, VDEV_CMD);
	if (ret)
		hdd_err("sgi failed:%d", ret);

	ret = wma_cli_set_command(wt_vdev_id(adapter), wmi_vdev_param_chwidth,
				  params->bw, VDEV_CMD);
	if (ret)
		hdd_err("chwidth failed:%d", ret);

	return ret;
}

static struct hdd_adapter *
wt_create_intf(struct hdd_context *hdd_ctx,
	       const struct wondertap_init_params *params)
{
	struct hdd_adapter_create_param create_params = {0};
	uint8_t mac_addr[QDF_MAC_ADDR_SIZE];

	create_params.num_sessions = 1;
	qdf_mem_copy(mac_addr, params->mac_addr, QDF_MAC_ADDR_SIZE);

	/*
	 * Ace2: use QDF_MONITOR_MODE (native mon session + set_mon_chan).
	 * Donor SM8850 uses QDF_PASSTHRU_MODE + PE session — not available here.
	 */
	return hdd_open_adapter(hdd_ctx, QDF_MONITOR_MODE, "wondertap%d",
				mac_addr, NET_NAME_UNKNOWN, true,
				&create_params);
}

static int wt_stop_intf(struct hdd_context *hdd_ctx, struct hdd_adapter *adapter)
{
	QDF_STATUS status;

	wlan_hdd_netif_queue_control(adapter,
				     WLAN_STOP_ALL_NETIF_QUEUE_N_CARRIER,
				     WLAN_CONTROL_PATH);
	if (!rtnl_is_locked()) {
		hdd_err("wt_stop_intf requires RTNL");
		return -EPERM;
	}
	dev_close(adapter->dev);

	status = qdf_event_reset(&g_wt_ctx->wondertap_vdev_event);
	if (QDF_IS_STATUS_ERROR(status))
		goto done;

	/* Ace2: mon PE session APIs exist; pe_session PASSTHRU does not */
	sme_delete_mon_session(hdd_ctx->mac_handle, wt_vdev_id(adapter));

	status = qdf_wait_for_event_completion(&g_wt_ctx->wondertap_vdev_event,
					       WLAN_WONDERTAP_VDEV_OP_TIMEOUT_MS);
	if (QDF_IS_STATUS_ERROR(status))
		hdd_err("teardown wait failed:%d", status);

	policy_mgr_decr_session_set_pcl(hdd_ctx->psoc, QDF_MONITOR_MODE,
					wt_vdev_id(adapter));

	hdd_stop_adapter(hdd_ctx, adapter);
	hdd_deinit_adapter(hdd_ctx, adapter, true);
	clear_bit(DEVICE_IFACE_OPENED, &adapter->event_flags);

	if (!hdd_is_any_interface_open(hdd_ctx))
		hdd_psoc_idle_timer_start(hdd_ctx);

done:
	return qdf_status_to_os_return(status);
}

static int wt_start_intf(struct hdd_context *hdd_ctx, struct hdd_adapter *adapter,
			 const struct wondertap_init_params *params)
{
	QDF_STATUS status;
	int ret;

	/*
	 * Mirror Ace2 STA+MON open path (hdd_mon_open):
	 *   start_adapter → set_mon_rx_cb (peer + mon session) →
	 *   set_mon_chan (waits monitor_mode_vdev_up_event) → enable_monitor_mode
	 */
	ret = hdd_start_adapter(adapter);
	if (ret) {
		hdd_err("start adapter failed %d", ret);
		return ret;
	}
	set_bit(DEVICE_IFACE_OPENED, &adapter->event_flags);

	/* STA+MON concurrency: native path checks mlme flag, not PM_STA_MODE */
	if (hdd_get_conparam() != QDF_GLOBAL_MONITOR_MODE &&
	    !ucfg_mlme_is_sta_mon_conc_supported(hdd_ctx->psoc) &&
	    hdd_get_adapter(hdd_ctx, QDF_STA_MODE)) {
		hdd_err("STA+MON concurrency not supported");
		ret = -EPERM;
		goto stop_adapter;
	}

	/* mon txrx ops + cdp peer + sme_create_mon_session */
	ret = hdd_set_mon_rx_cb(adapter->dev);
	if (ret) {
		hdd_err("hdd_set_mon_rx_cb failed %d", ret);
		goto stop_adapter;
	}

	/* wait mon vdev up if still in progress after session create */
	status = hdd_monitor_mode_vdev_status(adapter);
	if (QDF_IS_STATUS_ERROR(status)) {
		hdd_err("monitor mode vdev status %d", status);
		ret = qdf_status_to_os_return(status);
		goto delete_session;
	}

	status = wt_set_channel(hdd_ctx, adapter, &params->channel);
	if (QDF_IS_STATUS_ERROR(status)) {
		ret = qdf_status_to_os_return(status);
		goto delete_session;
	}

	ret = wt_set_fixed_tx_rate(adapter, &params->tx_rate);
	if (ret)
		hdd_err("fixed tx rate failed %d (continue)", ret);

	ret = hdd_enable_monitor_mode(adapter->dev);
	if (ret) {
		hdd_err("hdd_enable_monitor_mode failed %d", ret);
		goto delete_session;
	}

	policy_mgr_incr_active_session(hdd_ctx->psoc, QDF_MONITOR_MODE,
				       wt_vdev_id(adapter));

	wlan_hdd_netif_queue_control(adapter,
				     WLAN_START_ALL_NETIF_QUEUE_N_CARRIER,
				     WLAN_CONTROL_PATH);
	dev_open(adapter->dev, NULL);

	hdd_info("wt_start_intf OK vdev=%u freq=%u",
		 wt_vdev_id(adapter), params->channel.freq);
	return 0;

delete_session:
	sme_delete_mon_session(hdd_ctx->mac_handle, wt_vdev_id(adapter));
stop_adapter:
	hdd_stop_adapter(hdd_ctx, adapter);
	return ret;
}

static int wlan_hdd_wondertap_init(void **handle,
				   const struct wondertap_init_params *params)
{
	struct hdd_context *hdd_ctx = cds_get_context(QDF_MODULE_ID_HDD);
	struct osif_vdev_sync *vdev_sync;
	struct hdd_adapter *adapter;
	struct hdd_wondertap_context *wt_ctx;
	QDF_STATUS status;
	int errno;
	u32 magic;

	hdd_enter();
	if (!hdd_ctx || !params || !handle)
		return -EINVAL;

	/* Prefer soft fail over ASSERT_RTNL() — PANIC_ON_BUG turns BUG into reboot */
	if (!rtnl_is_locked()) {
		hdd_err("wondertap_init requires RTNL");
		return -EPERM;
	}

	/* Soft path: no mon/passthru adapter — safe on Ace2 until session path is green */
	if (soft_init) {
		if (g_wt_ctx)
			return -EBUSY;
		wt_ctx = qdf_mem_malloc(sizeof(*wt_ctx));
		if (!wt_ctx)
			return -ENOMEM;
		wt_ctx->hdd_ctx = hdd_ctx;
		wt_ctx->wt_adapter = NULL;
		get_random_bytes(&magic, sizeof(magic));
		if (!magic)
			magic = 0x574f4e44; /* 'WOND' */
		wt_ctx->magic = magic;
		g_wt_ctx = wt_ctx;
		*handle = (void *)(uintptr_t)magic;
		hdd_info("wondertap soft_init OK handle=%p", *handle);
		hdd_exit();
		return 0;
	}

	errno = osif_vdev_sync_create_and_trans(hdd_ctx->parent_dev, &vdev_sync);
	if (errno)
		return errno;

	errno = wlan_hdd_validate_context(hdd_ctx);
	if (errno)
		goto destroy_sync;

	if (hdd_get_conparam() != QDF_GLOBAL_MISSION_MODE) {
		errno = -EPERM;
		goto destroy_sync;
	}

	errno = hdd_trigger_psoc_idle_restart(hdd_ctx);
	if (errno)
		goto destroy_sync;

	wt_ctx = qdf_mem_malloc(sizeof(*wt_ctx));
	if (!wt_ctx) {
		errno = -ENOMEM;
		goto destroy_sync;
	}

	status = qdf_event_create(&wt_ctx->wondertap_vdev_event);
	if (QDF_IS_STATUS_ERROR(status)) {
		errno = qdf_status_to_os_return(status);
		goto free_ctx;
	}

	status = qdf_runtime_lock_init(&wt_ctx->wondertap_rtpm_lock);
	if (QDF_IS_STATUS_ERROR(status)) {
		errno = qdf_status_to_os_return(status);
		goto destroy_event;
	}

	status = qdf_wake_lock_create(&wt_ctx->wondertap_wakelock, "wlan_wondertap");
	if (QDF_IS_STATUS_ERROR(status)) {
		errno = qdf_status_to_os_return(status);
		goto destroy_rtpm;
	}

	qdf_wake_lock_acquire(&wt_ctx->wondertap_wakelock,
			      WIFI_POWER_EVENT_WAKELOCK_DRIVER_MIN);
	qdf_runtime_pm_prevent_suspend(&wt_ctx->wondertap_rtpm_lock);

	g_wt_ctx = wt_ctx;

	adapter = wt_create_intf(hdd_ctx, params);
	if (IS_ERR_OR_NULL(adapter)) {
		hdd_err("wt_create_intf failed");
		errno = -EIO;
		goto fail_create;
	}

	osif_vdev_sync_register(adapter->dev, vdev_sync);

	errno = wt_start_intf(hdd_ctx, adapter, params);
	if (errno) {
		hdd_err("wt_start_intf failed %d", errno);
		goto fail_start;
	}

	wt_ctx->hdd_ctx = hdd_ctx;
	wt_ctx->wt_adapter = adapter;
	get_random_bytes(&magic, sizeof(magic));
	if (!magic)
		magic = 0x574f4e44;
	wt_ctx->magic = magic;
	*handle = (void *)(uintptr_t)wt_ctx->magic;

	osif_vdev_sync_trans_stop(vdev_sync);
	hdd_info("wondertap full_init OK adapter=%s", adapter->dev->name);
	hdd_exit();
	return 0;

fail_start:
	osif_vdev_sync_unregister(adapter->dev);
	hdd_close_adapter(hdd_ctx, adapter, true);
fail_create:
	qdf_runtime_pm_allow_suspend(&wt_ctx->wondertap_rtpm_lock);
	qdf_wake_lock_release(&wt_ctx->wondertap_wakelock,
			      WIFI_POWER_EVENT_WAKELOCK_DRIVER_MIN);
	qdf_wake_lock_destroy(&wt_ctx->wondertap_wakelock);
destroy_rtpm:
	qdf_runtime_lock_deinit(&wt_ctx->wondertap_rtpm_lock);
destroy_event:
	qdf_event_destroy(&wt_ctx->wondertap_vdev_event);
free_ctx:
	qdf_mem_free(wt_ctx);
	g_wt_ctx = NULL;
destroy_sync:
	osif_vdev_sync_trans_stop(vdev_sync);
	osif_vdev_sync_destroy(vdev_sync);
	return errno;
}

static void wlan_hdd_wondertap_deinit(void *handle,
				      const struct wondertap_deinit_params *params)
{
	struct hdd_context *hdd_ctx;
	struct hdd_adapter *wt_adapter;
	struct osif_vdev_sync *vdev_sync;
	int errno;

	hdd_enter();
	if (!g_wt_ctx || handle != (void *)(uintptr_t)g_wt_ctx->magic)
		return;

	if (!rtnl_is_locked()) {
		hdd_err("wondertap_deinit requires RTNL");
		return;
	}
	hdd_ctx = g_wt_ctx->hdd_ctx;
	wt_adapter = g_wt_ctx->wt_adapter;

	/* soft_init never opened an adapter */
	if (!wt_adapter) {
		qdf_mem_free(g_wt_ctx);
		g_wt_ctx = NULL;
		hdd_exit();
		return;
	}

	errno = osif_vdev_sync_trans_start_wait(wt_adapter->dev, &vdev_sync);
	if (errno)
		return;

	wt_stop_intf(hdd_ctx, wt_adapter);
	osif_vdev_sync_unregister(wt_adapter->dev);
	hdd_close_adapter(hdd_ctx, wt_adapter, true);

	qdf_runtime_pm_allow_suspend(&g_wt_ctx->wondertap_rtpm_lock);
	qdf_wake_lock_release(&g_wt_ctx->wondertap_wakelock,
			      WIFI_POWER_EVENT_WAKELOCK_DRIVER_MIN);
	qdf_wake_lock_destroy(&g_wt_ctx->wondertap_wakelock);
	qdf_runtime_lock_deinit(&g_wt_ctx->wondertap_rtpm_lock);
	qdf_event_destroy(&g_wt_ctx->wondertap_vdev_event);
	qdf_mem_free(g_wt_ctx);
	g_wt_ctx = NULL;

	osif_vdev_sync_trans_stop(vdev_sync);
	osif_vdev_sync_destroy(vdev_sync);
	hdd_exit();
}

static int wlan_hdd_wondertap_set_freq(void *handle,
				       const struct wondertap_set_freq_params *params)
{
	struct osif_vdev_sync *vdev_sync;
	QDF_STATUS status;
	int errno;

	if (!g_wt_ctx || handle != (void *)(uintptr_t)g_wt_ctx->magic)
		return -EINVAL;

	errno = osif_vdev_sync_trans_start(g_wt_ctx->wt_adapter->dev, &vdev_sync);
	if (errno)
		return errno;

	status = wt_set_channel(g_wt_ctx->hdd_ctx, g_wt_ctx->wt_adapter, params);
	errno = qdf_status_to_os_return(status);
	osif_vdev_sync_trans_stop(vdev_sync);
	return errno;
}

static int wlan_hdd_wondertap_set_filter(void *handle,
					 enum wondertap_filter_type filter_type,
					 const void *params)
{
	/* Frame filter APIs differ by tree; accept and no-op for compile path */
	if (!g_wt_ctx || handle != (void *)(uintptr_t)g_wt_ctx->magic)
		return -EINVAL;
	if (filter_type != WONDERTAP_FILTER_TYPE_FRAME)
		return -EINVAL;
	return 0;
}

static int wlan_hdd_wondertap_set_fixed_tx_rate(void *handle,
						const struct wondertap_fixed_tx_rate_params *params)
{
	struct osif_vdev_sync *vdev_sync;
	int errno;

	if (!g_wt_ctx || handle != (void *)(uintptr_t)g_wt_ctx->magic)
		return -EINVAL;

	errno = osif_vdev_sync_op_start(g_wt_ctx->wt_adapter->dev, &vdev_sync);
	if (errno)
		return errno;

	errno = wt_set_fixed_tx_rate(g_wt_ctx->wt_adapter, params);
	osif_vdev_sync_op_stop(vdev_sync);
	return errno;
}

static int wlan_hdd_wondertap_set_tx_rate_mask(void *handle,
					       const struct wondertap_tx_rate_mask_params *params)
{
	(void)handle;
	(void)params;
	return -EOPNOTSUPP;
}

static int wlan_hdd_wondertap_get_capabilities(void *handle,
					       struct wondertap_capability *features)
{
	struct hdd_context *hdd_ctx = cds_get_context(QDF_MODULE_ID_HDD);

	(void)handle;
	if (!features)
		return -EINVAL;

	qdf_mem_zero(features, sizeof(*features));
	/* version must stay 0 for current wonder Soft-MAC */
	features->version = 0;
	features->bits.dynamic_freq = 1;
	features->bits.dynamic_fixed_tx_rate = 1;
	features->bits.frame_type_filter = 1;
	features->bits.custom_mgmt_retry_limit = 1;
	features->bits.custom_data_retry_limit = 1;
	if (hdd_ctx && hdd_ctx->psoc &&
	    policy_mgr_is_hw_dbs_capable(hdd_ctx->psoc))
		features->bits.sta_coexist = 1;

	return 0;
}

static const struct wondertap_ops wlan_drv_wondertap_ops = {
	.init = wlan_hdd_wondertap_init,
	.deinit = wlan_hdd_wondertap_deinit,
	.set_freq = wlan_hdd_wondertap_set_freq,
	.set_filter = wlan_hdd_wondertap_set_filter,
	.set_fixed_tx_rate = wlan_hdd_wondertap_set_fixed_tx_rate,
	.set_tx_rate_mask = wlan_hdd_wondertap_set_tx_rate_mask,
	.get_capabilities = wlan_hdd_wondertap_get_capabilities,
};

static const struct wondertap_priv wlan_drv_wondertap_priv = {
	.ver = WONDER_VERSION_1_4_1,
	.wonder_ops = &wlan_drv_wondertap_ops,
};

int wlan_hdd_wondertap_register_ops(struct device *dev)
{
	return pld_set_vendor_wonder_priv_data(dev, &wlan_drv_wondertap_priv);
}

void wlan_hdd_wondertap_unregister_ops(struct device *dev, bool force_cleanup)
{
	hdd_enter();
	pld_set_vendor_wonder_priv_data(dev, NULL);
	if (force_cleanup && g_wt_ctx) {
		void *h = (void *)(uintptr_t)g_wt_ctx->magic;
		struct wondertap_deinit_params p = {0};

		wlan_hdd_wondertap_deinit(h, &p);
	}
	hdd_exit();
}

void hdd_sme_passthrough_mode_callback(uint8_t vdev_id, bool is_up)
{
	if (!g_wt_ctx)
		return;
	qdf_event_set(&g_wt_ctx->wondertap_vdev_event);
}
