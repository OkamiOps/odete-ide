__nodeDefine("os", (module) => {
  const H = globalThis.__odete;
  module.exports = {
    EOL: "\n", platform: () => "darwin", type: () => "Darwin", arch: () => "arm64", release: () => H.osVersion, version: () => "iPadOS", machine: () => "arm64",
    homedir: () => H.cwd, tmpdir: () => H.tmpdir, hostname: () => "ipad", endianness: () => "LE", uptime: () => H.perfNow() / 1000, loadavg: () => [0, 0, 0],
    totalmem: () => 8 * 1024 ** 3, freemem: () => 4 * 1024 ** 3, availableParallelism: () => 4,
    cpus: () => Array.from({ length: 4 }, () => ({ model: "Apple", speed: 3000, times: { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 } })),
    networkInterfaces: () => ({ lo0: [{ address: "127.0.0.1", netmask: "255.0.0.0", family: "IPv4", mac: "00:00:00:00:00:00", internal: true, cidr: "127.0.0.1/8" }] }),
    userInfo: () => ({ username: "odete", uid: 501, gid: 20, shell: "/bin/odete", homedir: H.cwd }),
    constants: { signals: { SIGINT: 2, SIGTERM: 15, SIGKILL: 9 }, errno: {} }, devNull: "/dev/null",
  };
});
