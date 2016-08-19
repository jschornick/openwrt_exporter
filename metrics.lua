#!/usr/bin/lua

-- Metrics web server

-- Copyright (c) 2016 Jeff Schornick <jeff@schornick.org>
-- Copyright (c) 2015 Kevin Lyda
-- Licensed under the Apache License, Version 2.0

socket = require("socket")

-- Parsing

function space_split(s)
  elements = {}
  for element in s:gmatch("%S+") do
    table.insert(elements, element)
  end
  return elements
end

function line_split(s)
  elements = {}
  for element in s:gmatch("[^\n]+") do
    table.insert(elements, element)
  end
  return elements
end

function get_contents(filename)
  local f = io.open(filename, "rb")
  local contents = ""
  if f then
    contents = f:read "*a"
    f:close()
  end

  return contents
end

-- Metric printing

function print_metric_type(metric, mtype)
  this_metric = metric
  output("# TYPE " .. metric .. " " .. mtype)
end

function print_metric(labels, value)
  if labels then
    output(string.format("%s{%s} %s", this_metric, labels, value))
  else
    output(string.format("%s %s", this_metric, value))
  end
end

function metrics_cpu()
  local stat = get_contents("/proc/stat")

  -- system boot time, seconds since epoch
  print_metric_type("node_boot_time", "gauge")
  print_metric(nil, string.match(stat, "btime ([0-9]+)"))

  -- context switches since boot (all CPUs)
  print_metric_type("node_context_switches", "counter")
  print_metric(nil, string.match(stat, "ctxt ([0-9]+)"))

  -- cpu times, per CPU, per mode
  local cpu_mode = {"user", "nice", "system", "idle", "iowait", "irq",
                    "softirq", "steal", "guest", "guest_nice"}
  local i = 0
  print_metric_type("node_cpu", "counter")
  while string.match(stat, string.format("cpu%d ", i)) do
    cpu = space_split(string.match(stat, string.format("cpu%d ([0-9 ]+)", i)))
    local label = string.format('cpu="cpu%d",mode="%%s"', i)
    for ii, mode in ipairs(cpu_mode) do
      print_metric(string.format(label, mode), cpu[ii] / 100)
    end
    i = i + 1
  end

  -- interrupts served
  print_metric_type("node_intr", "counter")
  print_metric(nil, string.match(stat, "intr ([0-9]+)"))

  -- processes forked
  print_metric_type("node_forks", "counter")
  print_metric(nil, string.match(stat, "processes ([0-9]+)"))

  -- processes running
  print_metric_type("node_procs_running", "gauge")
  print_metric(nil, string.match(stat, "procs_running ([0-9]+)"))

  -- processes blocked for I/O
  print_metric_type("node_procs_blocked", "gauge")
  print_metric(nil, string.match(stat, "procs_blocked ([0-9]+)"))
end

function metrics_load_averages()
  local loadavg = space_split(get_contents("/proc/loadavg"))

  print_metric_type("node_load1", "gauge")
  print_metric(nil, loadavg[1])
  print_metric_type("node_load15", "gauge")
  print_metric(nil, loadavg[3])
  print_metric_type("node_load5", "gauge")
  print_metric(nil, loadavg[2])
end

function metrics_memory()
  local meminfo = line_split(get_contents("/proc/meminfo"):gsub("[):]", ""):gsub("[(]", "_"))

  for i, mi in ipairs(meminfo) do
    local mia = space_split(mi)
    print_metric_type("node_memory_" .. mia[1], "gauge")
    if #mia == 3 then
      print_metric(nil, mia[2] * 1024)
    else
      print_metric(nil, mia[2])
    end
  end
end

function metrics_file_handles()
  local file_nr = space_split(get_contents("/proc/sys/fs/file-nr"))

  print_metric_type("node_filefd_allocated", "gauge")
  print_metric(nil, file_nr[1])
  print_metric_type("node_filefd_maximum", "gauge")
  print_metric(nil, file_nr[3])
end

function metrics_network()
  -- NOTE: Both of these are missing in OpenWRT kernels.
  --       See: https://dev.openwrt.org/ticket/15781
  local netstat = get_contents("/proc/net/netstat") .. get_contents("/proc/net/snmp")

  -- all devices
  local netsubstat = {"IcmpMsg", "Icmp", "IpExt", "Ip", "TcpExt", "Tcp", "UdpLite", "Udp"}
  for i, nss in ipairs(netsubstat) do
    local substat_s = string.match(netstat, nss .. ": ([A-Z][A-Za-z0-9 ]+)")
    if substat_s then
      local substat = space_split(substat_s)
      local substatv = space_split(string.match(netstat, nss .. ": ([0-9 -]+)"))
      for ii, ss in ipairs(substat) do
        print_metric_type("node_netstat_" .. nss .. "_" .. ss, "gauge")
        print_metric(nil, substatv[ii])
      end
    end
  end
end

function metrics_network_devices()
  local netdevstat = line_split(get_contents("/proc/net/dev"))
  local netdevsubstat = {"receive_bytes", "receive_packets", "receive_errs",
                   "receive_drop", "receive_fifo", "receive_frame", "receive_compressed",
                   "receive_multicast", "transmit_bytes", "transmit_packets",
                   "transmit_errs", "transmit_drop", "transmit_fifo", "transmit_colls",
                   "transmit_carrier", "transmit_compressed"}
  for i, line in ipairs(netdevstat) do
    netdevstat[i] = string.match(netdevstat[i], "%S.*")
  end
  local nds_table = {}
  local devs = {}
  for i, nds in ipairs(netdevstat) do
    local dev, stat_s = string.match(netdevstat[i], "([^:]+): (.*)")
    if dev then
      nds_table[dev] = space_split(stat_s)
      table.insert(devs, dev)
    end
  end
  for i, ndss in ipairs(netdevsubstat) do
    print_metric_type("node_network_" .. ndss, "gauge")
    for ii, d in ipairs(devs) do
      print_metric('device="' .. d .. '"', nds_table[d][i])
    end
  end
end

function metrics_time()
  -- current time
  print_metric_type("node_time", "counter")
  print_metric(nil, os.time())
end

function metrics_uname()
  local uname = space_split(io.popen("uname -a"):read("*a"))
  print_metric_type("node_uname_info", "gauge")
  -- TODO: check these fields
  print_metric(string.format('domainname="(none)",machine="%s",nodename="%s",' ..
                               'release="%s",sysname="%s",version="%s %s %s %s %s %s %s"',
                             uname[11], uname[2], uname[3], uname[1], uname[4], uname[5],
                             uname[6], uname[7], uname[8], uname[9], uname[10]), 1)
end

function print_all_metrics()
  metrics_cpu()
  metrics_load_averages()
  metrics_memory()
  metrics_file_handles()
  metrics_network()
  metrics_network_devices()
  metrics_time()
  metrics_uname()
end

-- Web server-specific functions

function http_ok_header()
  output("HTTP/1.1 200 OK\r")
  output("Server: lua-metrics\r")
  output("Content-Type: text/plain; version=0.0.4\r")
  output("\r")
end

function http_not_found()
  output("HTTP/1.1 404 Not Found\r")
  output("Server: lua-metrics\r")
  output("Content-Type: text/plain\r")
  output("\r")
  output("ERROR: File Not Found.")
end

function serve(request)
  if not string.match(request, "GET /metrics.*") then
    http_not_found()
  else
    http_ok_header()
    print_all_metrics()
  end
  client:close()
  return true
end

-- Main program

for k,v in ipairs(arg) do
  if (v == "-p") or (v == "--port") then
    port = arg[k+1]
  end
end

if port then
  server = assert(socket.bind("*", port))

  while 1 do
    client = server:accept()
    client:settimeout(60)
    local request, err = client:receive()

    if not err then
      output = function (str) client:send(str.."\n") end
      if not serve(request) then
        break
      end
    end
  end
else
  output = print
  print_all_metrics()
end
