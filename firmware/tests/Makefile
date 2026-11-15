HOST_CC      := gcc
HOST_CFLAGS  := -O0 -g -Wall -Wextra -I../core -I../app

.PHONY: all clean

all: run

test_aip_cmd_host: test_aip_cmd_host.c ../core/aip_cmd.c ../core/aip_cmd.h
	$(HOST_CC) $(HOST_CFLAGS) -o $@ test_aip_cmd_host.c ../core/aip_cmd.c

run: test_aip_cmd_host
	./test_aip_cmd_host

clean:
	rm -f test_aip_cmd_host
