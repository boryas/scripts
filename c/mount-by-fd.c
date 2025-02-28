#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
	char src_path[256];
	char tgt_path[256];

	if (argc < 3) {
		fprintf(stderr, "usage: mount-by-fd <dev> <mnt>");
	}
	unshare(CLONE_NEWNS);
	int src = open(argv[1], O_RDWR|O_NOCTTY|O_PATH);
	unshare(CLONE_NEWNS);
	int tgt = open(argv[2], O_RDONLY|O_NOFOLLOW|O_PATH);

	snprintf(src_path, sizeof(src_path), "/proc/self/fd/%d", src);
	snprintf(tgt_path, sizeof(tgt_path), "/proc/self/fd/%d", tgt);
	int ret = mount(src_path, tgt_path, "btrfs", MS_NODEV|MS_RDONLY, NULL);
	printf("%s %s %s src fd %d tgt fd %d returned: %d\n", argv[0], argv[1], argv[2], src, tgt, errno);
	return ret;

	/* fork mode */
	pid_t pid = fork();

	if (pid < 0) {
		printf("fork failed %d\n", errno);
	} else if (pid == 0) {
		int src = open(argv[1], O_RDONLY|O_NOCTTY|O_NONBLOCK);
		unshare(CLONE_NEWNS);
		int tgt = open(argv[2], O_RDONLY|O_NOFOLLOW|O_PATH);

		snprintf(src_path, sizeof(src_path), "/proc/self/fd/%d", src);
		snprintf(tgt_path, sizeof(tgt_path), "/proc/self/fd/%d", tgt);
		int ret = mount(src_path, tgt_path, "btrfs", MS_NODEV|MS_RDONLY, NULL);
		printf("%s %s %s src fd %d tgt fd %d returned: %d\n", argv[0], argv[1], argv[2], src, tgt, errno);
		return ret;
	} else {
		waitpid(pid, NULL, 0);
	}

	return 0;
}
