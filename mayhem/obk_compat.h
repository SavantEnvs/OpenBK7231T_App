/* Force-included when compiling the simulator on glibc >= 2.38, where <string.h> declares
   strcasestr and conflicts with upstream's own definition of that name in src/new_common.c. */
#include <string.h>
#define strcasestr obk_strcasestr
