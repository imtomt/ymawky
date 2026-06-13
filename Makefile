SRCS := $(wildcard src/*.S)
OBJS := $(SRCS:src/%.S=%.o)
LDFLAGS := -z noexecstack -e _main

ymawky: $(OBJS)
	ld $(OBJS) -o ymawky $(LDFLAGS)
	rm -f $(OBJS)

%.o: src/%.S $(SRCS)
	cpp $< -o $*.s
	as $*.s -o $@
	rm $*.s

clean:
	rm -f ymawky $(OBJS)
