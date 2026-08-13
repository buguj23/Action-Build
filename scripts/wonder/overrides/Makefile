KBUILD_OPTIONS += CONFIG_WONDER_SUPPORT=m

KERNEL_SRC ?= /lib/modules/$(shell uname -r)/build
M ?= $(shell pwd)

modules modules_install clean:
	$(MAKE) -C $(KERNEL_SRC) M=$(M) $(KBUILD_OPTIONS) W=1 $(@)
