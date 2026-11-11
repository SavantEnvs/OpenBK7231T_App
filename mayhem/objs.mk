# Wrapper over upstream's custom.mk (Linux simulator build) that exposes just the object list.
include custom.mk

.PHONY: objs print-objs print-includes
objs: $(OBJS)
print-objs:
	@echo $(OBJS)
print-includes:
	@echo $(INCLUDES)
