#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#define MAGIC1 0xDEADBEEF
#define MAGIC2 0xCAFEBABE

#define PROFILE_VER 2
#define PKG_NAME_LEN 256
#define MAX_GROUPS 32
#define DOMAIN_LEN 64

#define IOCTL_MAGIC 'K'
#define IOCTL_UID_SHOULD_UMOUNT _IOC(_IOC_READ | _IOC_WRITE, IOCTL_MAGIC, 9, 0)
#define IOCTL_GET_MANAGER_APPID _IOC(_IOC_READ, IOCTL_MAGIC, 10, 0)
#define IOCTL_GET_APP_PROFILE _IOC(_IOC_READ | _IOC_WRITE, IOCTL_MAGIC, 11, 0)
#define IOCTL_SET_APP_PROFILE _IOC(_IOC_WRITE, IOCTL_MAGIC, 12, 0)

struct root_profile {
    int32_t uid;
    int32_t gid;
    int32_t groups_count;
    int32_t groups[MAX_GROUPS];
    struct {
        uint64_t effective;
        uint64_t permitted;
        uint64_t inheritable;
    } capabilities;
    char selinux_domain[DOMAIN_LEN];
    int32_t namespaces;
};

struct non_root_profile {
    bool umount_modules;
};

struct app_profile {
    uint32_t version;
    char key[PKG_NAME_LEN];
    int32_t current_uid;
    bool allow_su;
    union {
        struct {
            bool use_default;
            char template_name[PKG_NAME_LEN];
            struct root_profile profile;
        } rp_config;
        struct {
            bool use_default;
            struct non_root_profile profile;
        } nrp_config;
    };
};

struct uid_query {
    uint32_t uid;
    uint8_t should_umount;
};

struct manager_query {
    uint32_t appid;
};

static int fd = -1;

static int call_ksu(unsigned long op, void *arg) {
    return ioctl(fd, op, arg) >= 0;
}

static void print_error() {
    fprintf(stderr, "ERROR: %s\n", strerror(errno));
}

static int open_interface() {
    syscall(SYS_reboot, MAGIC1, MAGIC2, 0, &fd);
    return fd;
}

int main(int argc, char **argv) {

    if (argc < 3) {
        fprintf(stderr,
                "ksu_profile\n"
                "Usage: %s <uid> <package>\n",
                argv[0]);
        return 1;
    }

    long uid = atol(argv[1]);
    const char *pkg = argv[2];

    if (open_interface() == -1) {
        print_error();
        return 1;
    }

    struct uid_query check = {0};

    if (!call_ksu(IOCTL_UID_SHOULD_UMOUNT, &check)) {
        print_error();
        return 1;
    }

    if (!check.should_umount)
        return 0;

    struct manager_query mgr = {0};

    if (!call_ksu(IOCTL_GET_MANAGER_APPID, &mgr)) {
        print_error();
        return 1;
    }

    if (setuid(mgr.appid) != 0) {
        print_error();
        return 1;
    }

    struct app_profile profile;
    memset(&profile, 0, sizeof(profile));

    profile.current_uid = uid;

    if (!call_ksu(IOCTL_GET_APP_PROFILE, &profile)) {
        printf("Create profile for %s\n", pkg);
        profile.version = PROFILE_VER;
        strncpy(profile.key, pkg, sizeof(profile.key) - 1);
    }

    profile.nrp_config.use_default = false;
    profile.nrp_config.profile.umount_modules = false;

    if (!call_ksu(IOCTL_SET_APP_PROFILE, &profile)) {
        print_error();
        return 1;
    }

    return 0;
}
