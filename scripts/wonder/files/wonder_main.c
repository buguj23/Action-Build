/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Google Wonder WiFi Virtual Soft-MAC Driver
 *
 * Ace2 Pro stage-4: software platform bind path (no DTBO / no wondertap-provider
 * phandle required). Falls back to DT path when of_node + phandle are present.
 *
 * Binding:
 *   wonder master  --component-->  platform "vendor-wlan-wonder" (cnss)
 *   kiwi registers wondertap_priv via cnss_set_vendor_wonder_priv_data()
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/version.h>
#include <linux/init.h>
#include <linux/netdevice.h>
#include <linux/platform_device.h>
#include <linux/component.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/device.h>
#include <linux/slab.h>
#include <linux/string.h>

#include "core.h"
#include "mac80211.h"
#include "wonder_log.h"
#include "include/wonder/wondertap.h"
#include "wondertap_internal.h"

/* Module parameter for setting the physical device name */
module_param(physical_name, charp, 0444);
MODULE_PARM_DESC(physical_name, "Interface name to use (e.g., wlan0, radiotap0, ...)");

/* Software bind target: must match cnss id_table name "vendor-wlan-wonder" */
#define WONDER_PROVIDER_PDEV_NAME	"vendor-wlan-wonder"
#define WONDER_SW_PDEV_NAME		"wonder"

static struct platform_device *wonder_sw_pdev;

#define WONDER_MAX_COMPAT_VERSIONS 4
static int wonder_ver_match_table[WONDER_VERSION_MAX][WONDER_MAX_COMPAT_VERSIONS] = {
	{ WONDER_VERSION_1_0, -1 },
	{ WONDER_VERSION_1_1, -1 },
	{ WONDER_VERSION_1_2, -1 },
	{ WONDER_VERSION_1_3, -1 },
	{ WONDER_VERSION_1_4, -1 },
	{ WONDER_VERSION_1_4_1, WONDER_VERSION_1_4, -1 },
	{ WONDER_VERSION_1_5, WONDER_VERSION_1_4, WONDER_VERSION_1_4_1, -1 },
	{ WONDER_VERSION_1_5_1, WONDER_VERSION_1_4, WONDER_VERSION_1_5, WONDER_VERSION_1_4_1 },
};

static bool wonder_ver_can_support(enum wondertap_ver slave, enum wondertap_ver master)
{
	int i;

	if (master < 0 || master >= WONDER_VERSION_MAX)
		return false;
	if (slave < 0 || slave >= WONDER_VERSION_MAX)
		return false;

	for (i = 0; i < WONDER_MAX_COMPAT_VERSIONS; i++) {
		if (wonder_ver_match_table[master][i] == -1)
			break;
		if (wonder_ver_match_table[master][i] == slave)
			return true;
	}
	return false;
}

static struct platform_device *wonder_find_provider_pdev(struct wondertap_data *wondertap)
{
	struct device *dev;
	struct platform_device *pdev;

	if (wondertap->wlan_node) {
		pdev = of_find_device_by_node(wondertap->wlan_node);
		if (pdev)
			return pdev;
	}

	/* Software path: match platform device by name (no DT). */
	dev = bus_find_device_by_name(&platform_bus_type, NULL,
				      WONDER_PROVIDER_PDEV_NAME);
	if (dev)
		return to_platform_device(dev);

	return NULL;
}

static int wonder_master_bind(struct device *dev)
{
	struct wondertap_data *wondertap = dev_get_drvdata(dev);
	struct platform_device *wlan_pdev;
	struct wondertap_priv *wlan_priv;
	int ret;

	dev_info(dev, "%s(): Binding (stage4 software/DT)...\n", __func__);

	ret = component_bind_all(dev, NULL);
	if (ret) {
		dev_err(dev, "%s(): component_bind_all failed %d\n", __func__, ret);
		return ret;
	}

	wlan_pdev = wonder_find_provider_pdev(wondertap);
	if (!wlan_pdev) {
		dev_err(dev, "%s(): Cannot find wlan provider pdev '%s'!\n",
			__func__, WONDER_PROVIDER_PDEV_NAME);
		component_unbind_all(dev, NULL);
		return -ENODEV;
	}

	wlan_priv = platform_get_drvdata(wlan_pdev);
	if (!wlan_priv || !wlan_priv->wonder_ops)
		goto err;

	if (!wonder_ver_can_support(wlan_priv->ver, wondertap->ver)) {
		dev_err(dev, "%s(): wondertap interface version mismatch(%d,%d)!\n",
			__func__, wlan_priv->ver, wondertap->ver);
		goto err;
	}

	/* All matched, hook the ops to wondertap interface. */
	wondertap_register_ops(wlan_priv->wonder_ops);
	wondertap->wonder_ops = wlan_priv->wonder_ops;
	put_device(&wlan_pdev->dev);
	dev_info(dev, "%s(): Connected to wlan ver %d (cur: wonder ver %d) provider=%s!\n",
		 __func__, wlan_priv->ver, wondertap->ver,
		 dev_name(&wlan_pdev->dev));
	return 0;
err:
	dev_err(dev, "%s(): wlan driver data invalid!\n", __func__);
	put_device(&wlan_pdev->dev);
	component_unbind_all(dev, NULL);
	return -EINVAL;
}

static void wonder_master_unbind(struct device *dev)
{
	struct wondertap_data *wondertap = dev_get_drvdata(dev);

	dev_info(dev, "%s(): Unbinding...\n", __func__);

	wondertap_unregister_ops(wondertap->wonder_ops);
	component_unbind_all(dev, NULL);
}

static const struct component_master_ops wonder_comp_ops = {
	.bind = wonder_master_bind,
	.unbind = wonder_master_unbind,
};

/* DT path: match component by of_node pointer. */
static int wonder_compare_of(struct device *dev, void *data)
{
	return dev->of_node == data;
}

/*
 * Software path: match platform device named vendor-wlan-wonder.
 * component core walks devices; name may be "vendor-wlan-wonder" or with id.
 */
static int wonder_compare_name(struct device *dev, void *data)
{
	const char *want = data;
	const char *have = dev_name(dev);

	if (!want || !have)
		return 0;
	if (!strcmp(have, want))
		return 1;
	/* platform_device_register_simple may produce name.id */
	if (!strncmp(have, want, strlen(want)) &&
	    (have[strlen(want)] == '\0' || have[strlen(want)] == '.'))
		return 1;
	if (dev->bus == &platform_bus_type) {
		struct platform_device *pdev = to_platform_device(dev);

		if (pdev->name && !strcmp(pdev->name, want))
			return 1;
	}
	return 0;
}

static int wonder_probe(struct platform_device *pdev)
{
	struct wonder_data *wonder;
	struct wondertap_data *wondertap;
	struct component_match *match = NULL;
	struct device_node *provider_node = NULL;
	int ret;

	dev_info(&pdev->dev, "%s(): probe (of_node=%s)\n", __func__,
		 pdev->dev.of_node ? "yes" : "no-software");

	wonder = wonder_mac80211_init();
	if (!wonder)
		return -ENODEV;

	wondertap = &wonder->wondertap_data;
	wondertap->ver = WONDER_VERSION_1_5_1;
	platform_set_drvdata(pdev, wondertap);

	if (pdev->dev.of_node) {
		provider_node = of_parse_phandle(pdev->dev.of_node,
						 "wondertap-provider", 0);
		if (provider_node) {
			wondertap->wlan_node = provider_node;
			component_match_add_release(&pdev->dev, &match, NULL,
						    wonder_compare_of,
						    provider_node);
			of_node_put(provider_node);
			dev_info(&pdev->dev, "%s(): DT wondertap-provider path\n",
				 __func__);
		} else {
			dev_warn(&pdev->dev,
				 "%s(): of_node present but no wondertap-provider; falling back to software name match\n",
				 __func__);
		}
	}

	if (!match) {
		/* No DT phandle: match cnss software/name provider. */
		wondertap->wlan_node = NULL;
		component_match_add_release(&pdev->dev, &match, NULL,
					    wonder_compare_name,
					    (void *)WONDER_PROVIDER_PDEV_NAME);
		dev_info(&pdev->dev,
			 "%s(): software bind path provider='%s'\n",
			 __func__, WONDER_PROVIDER_PDEV_NAME);
	}

	ret = component_master_add_with_match(&pdev->dev, &wonder_comp_ops, match);
	if (ret) {
		dev_err(&pdev->dev, "%s(): component_master_add failed %d\n",
			__func__, ret);
		wonder_mac80211_exit();
		return ret;
	}

	dev_info(&pdev->dev, "%s(): Wonder probe/bind master registered OK\n",
		 __func__);
	return wonder_debugfs_init(wonder);
}

static void wonder_remove(struct platform_device *pdev)
{
	component_master_del(&pdev->dev, &wonder_comp_ops);
	wonder_debugfs_exit();
	wonder_mac80211_exit();
}

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 11, 0)
static int wonder_remove_wrapper(struct platform_device *pdev)
{
	wonder_remove(pdev);
	return 0;
}
#define wonder_remove wonder_remove_wrapper
#endif /* LINUX_VERSION_CODE < KERNEL_VERSION(6, 11, 0) */

static const struct of_device_id wonder_dt_ids[] = {
	{ .compatible = "google,wonder-drv-v1" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, wonder_dt_ids);

static struct platform_driver wonder_driver = {
	.probe = wonder_probe,
	.remove = wonder_remove,
	.driver = {
		.name = WONDER_SW_PDEV_NAME,
		.of_match_table = wonder_dt_ids,
	},
};

static int __init wonder_module_init(void)
{
	int ret;

	ret = platform_driver_register(&wonder_driver);
	if (ret) {
		pr_err("wonder: platform_driver_register failed %d\n", ret);
		return ret;
	}

	/*
	 * Always register a software platform device so probe runs without
	 * google,wonder-drv-v1 DT. Name match against driver->name = "wonder".
	 * If a DT node already exists, both may probe; DT path is preferred
	 * inside probe when of_node+phandle are present. Extra software pdev
	 * is acceptable for Ace2 Pro no-DTBO testing.
	 */
	wonder_sw_pdev = platform_device_register_simple(WONDER_SW_PDEV_NAME,
							 PLATFORM_DEVID_NONE,
							 NULL, 0);
	if (IS_ERR(wonder_sw_pdev)) {
		ret = PTR_ERR(wonder_sw_pdev);
		pr_err("wonder: software pdev register failed %d\n", ret);
		wonder_sw_pdev = NULL;
		platform_driver_unregister(&wonder_driver);
		return ret;
	}

	pr_info("wonder: software pdev '%s' registered (stage4 no-DT bind)\n",
		WONDER_SW_PDEV_NAME);
	return 0;
}

static void __exit wonder_module_exit(void)
{
	if (wonder_sw_pdev) {
		platform_device_unregister(wonder_sw_pdev);
		wonder_sw_pdev = NULL;
	}
	platform_driver_unregister(&wonder_driver);
}

module_init(wonder_module_init);
module_exit(wonder_module_exit);

MODULE_DESCRIPTION("Google Wonder Virtual mac80211 Driver (Ace2 Pro stage4 no-DT)");
MODULE_LICENSE("GPL");
MODULE_AUTHOR("Google Android WiFi Team");
