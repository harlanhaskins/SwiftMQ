#ifndef SWIFTMQ_SHIMS_H
#define SWIFTMQ_SHIMS_H

#include <fcntl.h>
#include <sys/mman.h>

int swiftmq_shm_open(const char *name, int oflag, mode_t mode);

#endif /* SWIFTMQ_SHIMS_H */
