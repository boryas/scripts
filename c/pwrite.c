#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main() {
  int ret;
  int fd;

  printf("%lu, %lu\n", sizeof(int), sizeof(ssize_t));
  
  fd = open("epipe-f", O_CREAT | O_RDWR, S_IWUSR | S_IRUSR);

  if (!fd) {
    printf("failed to open file: %d\n", errno);
    exit(1);
  }

  ret = ftruncate(fd, 420);
  if (ret < 0) {
    printf("truncate failed: %d\n", errno);
    exit(1);
  }

  printf("truncated. sleeping\n");
  sleep(30);

  ret = pwrite(fd, "wat", 4, 42);
  if (ret < 0) {
    printf("pwrite failed: %d\n", errno);
    exit(1);
  }
  printf("pwrite succeded: %d\n", ret);
  
  return 0;
}
