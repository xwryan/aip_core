#include "aip_cmd.h"
#include "aip_chip.h"

// Example business handler — square a number passed as x=N.
static void do_my_square(const char *args) {
    int x = cmd_get_int(args, "x", 0);
    cmd_return("square=%d", x * x);
}

// Example: add two numbers x and y.
static void do_my_add(const char *args) {
    int x = cmd_get_int(args, "x", 0);
    int y = cmd_get_int(args, "y", 0);
    cmd_return("sum=%d", x + y);
}

void user_register(void) {
    cmd_register("my_square", do_my_square);
    cmd_register("my_add",    do_my_add);
}
