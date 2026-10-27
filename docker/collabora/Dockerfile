# ═══════════════════════════════════════════════════════════════════
# Collabora Online with file-capabilities on coolwsd
# ═══════════════════════════════════════════════════════════════════
# Thin layer over the upstream `collabora/code` image that grants
# cap_sys_admin + cap_mknod to the coolwsd binary via setcap. Needed
# so the non-root `cool` user inside the container can exercise mount
# namespaces and bind-mount /opt/cool/systemplate into each document
# jail — Kubernetes pod-level `capabilities.add` only puts the caps in
# the bounding set for non-root processes; file capabilities make them
# effective regardless of the caller's uid.
#
# Build args:
#   UPSTREAM_TAG — Collabora CODE tag to base on (override at build time)
#
# Corresponding pod spec requirements:
#   - namespace PSA: privileged (so the caps are admissible)
#   - securityContext.capabilities.add: [SYS_ADMIN, MKNOD]
#   - no runAsUser override (coolwsd refuses to start as root)
#
# Multi-stage build: upstream images >=26.04 are distroless (no /bin/sh),
# so we install setcap in a builder stage and copy it, with its own libc
# and loader, into /opt/setcap of the upstream image.
ARG UPSTREAM_TAG=26.04.5.2.1

# ── Stage 1: builder with setcap ────────────────────────────────
FROM debian:bookworm-slim AS builder
RUN apt-get update \
    && apt-get install -y --no-install-recommends libcap2-bin \
    && rm -rf /var/lib/apt/lists/*

# ── Stage 2: final image (upstream Collabora) ───────────────────
FROM collabora/code:${UPSTREAM_TAG}@sha256:c7415b963e32eb0986a562583f154d36d3d7a461e1ddfb660a95e87094328acb

USER root

# Copy setcap/getcap together with the builder's own libc and loader into
# a private directory. Never copy them over the system paths: the upstream
# image ships a newer glibc, and replacing /lib/x86_64-linux-gnu/libc.so.6
# with bookworm's 2.36 makes coolwsd fail with "GLIBC_2.38 not found".
# The tools are run through the private loader in exec form (no shell).
COPY --from=builder /usr/sbin/setcap /usr/sbin/getcap /opt/setcap/
COPY --from=builder /lib/x86_64-linux-gnu/libcap.so.2 /lib/x86_64-linux-gnu/libc.so.6 /lib64/ld-linux-x86-64.so.2 /opt/setcap/

# The upstream image ships two forkit binaries:
#   /usr/bin/coolforkit-caps — uses CAP_SYS_ADMIN directly to bind-mount
#                              /opt/cool/systemplate into each jail.
#                              Preferred when caps are available.
#   /usr/bin/coolforkit-ns   — creates a user namespace, maps uid 0,
#                              and bind-mounts from inside. Used as
#                              a fallback when caps aren't available.
#
# The upstream image pre-sets cap_chown,cap_fowner,cap_sys_chroot on
# coolforkit-caps but not cap_sys_admin, which means coolwsd routes
# every document session through coolforkit-ns. coolforkit-ns is a
# separate binary with no file caps, so once coolwsd fork+execs it,
# the non-root `cool` user's CapEff drops to 0 and the CLONE_NEWNS
# unshare fails with EPERM — exactly what surfaces the admin-console
# "Langsame Einrichtung des Kit-Jails" red warning.
#
# Fix: add CAP_SYS_ADMIN + CAP_MKNOD to coolforkit-caps so coolwsd
# picks the caps path, and also setcap coolwsd itself so its own
# startup bind-mount self-test passes (needed before coolwsd will
# mark bind-mounting as usable at all).
RUN ["/opt/setcap/ld-linux-x86-64.so.2", "--library-path", "/opt/setcap", "/opt/setcap/setcap", \
     "cap_chown,cap_fowner,cap_mknod,cap_sys_admin,cap_sys_chroot=ep", "/usr/bin/coolforkit-caps", \
     "cap_chown,cap_fowner,cap_mknod,cap_sys_admin,cap_sys_chroot,cap_setuid,cap_setgid=ep", "/usr/bin/coolforkit-ns", \
     "cap_sys_admin,cap_mknod,cap_setuid,cap_setgid=eip", "/usr/bin/coolwsd"]
RUN ["/opt/setcap/ld-linux-x86-64.so.2", "--library-path", "/opt/setcap", "/opt/setcap/getcap", \
     "/usr/bin/coolforkit-caps", "/usr/bin/coolforkit-ns", "/usr/bin/coolwsd"]

# Collabora's own entrypoint refuses to start as root, so we flip back
# to the image's original user (uid 1001, cool). File capabilities
# survive the uid switch on exec.
USER 1001
