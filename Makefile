SRCS := $(wildcard src/*.S)
OBJS := $(SRCS:src/%.S=build/%.o)
PREPROC := $(SRCS:src/%.S=build/%.s)

ASFLAGS := --warn --fatal-warnings
LDFLAGS := -z noexecstack -z relro -z now -e _start --gc-sections -O2

.PHONY: all debug clean
.INTERMEDIATE: $(PREPROC)

all: ymawky

debug: LDFLAGS := -z noexecstack -z relro -z now -e _start
debug: ASFLAGS := --warn --fatal-warnings --gdawrf-5
debug: ymawky

ymawky: $(OBJS)
	ld $(OBJS) -o ymawky $(LDFLAGS)

build/%.s: src/%.S | build
	cpp $< -o $@

build/%.o: build/%.s
	as $< -o $@ $(ASFLAGS)

build:
	mkdir -p build

clean:
	rm -rf ymawky build
