#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <sys/mount.h>
#include <sys/wait.h>
#include <unistd.h>

void do_unshare() {
	printf("unshare in pid %d\n", getpid());
	unshare(CLONE_NEWNS);
}

void do_sleep(int duration) {
	printf("sleep %d in pid %d\n", duration, getpid());
	sleep(duration);
}

int main(int argc, char **argv) {
	do_unshare();
	int fd = open("/dev/loop0", O_RDONLY);
	printf("%d %d\n", getpid(), fd);
	do_sleep(10);
	pid_t pid = fork();
	if (pid < 0)
		return errno;
	if (pid == 0) {
	/* child */
		do_sleep(30);
		return 0;
	} else {
	/* parent */
		do_unshare();
		waitpid(pid, NULL, 0);
		return 0;
	}
}
