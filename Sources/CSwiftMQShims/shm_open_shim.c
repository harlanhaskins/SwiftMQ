#include "SwiftMQShims.h"

int swiftmq_shm_open(const char *name, int oflag, mode_t mode) {
    return shm_open(name, oflag, mode);
}
