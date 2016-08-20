#!/usr/bin/lua

-- Metrics web server

-- Copyright (c) 2016 Jeff Schornick <jeff@schornick.org>
-- Copyright (c) 2015 Kevin Lyda
-- Licensed under the Apache License, Version 2.0

socket = require("socket")

-- Allow us to call unpack under both lua5.1 and lua5.2+
local unpack = unpack or table.unpack

-- This table defines the scrapers to run.
-- Each corresponds directly to a scraper_<name> function.
scrapers = { "cpu", "load_averages", "memory", "file_handles", "network",
             "network_devices", "time", "uname"}

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

function print_metric(metric, labels, value)
  local label_string = ""
  if labels then
    for label,value in pairs(labels) do
      label_string =  label_string .. label .. '="' .. value .. '",'
    end
    label_string = "{" .. string.sub(label_string, 1, -2) .. "}"
  end
  output(string.format("%s%s %s", metric, label_string, value))
end

function metric(name, mtype, labels, value)
  output("# TYPE " .. name .. " " .. mtype)
  local outputter = function(labels, value)
    print_metric(name, labels, value)
  end
  if value then
    outputter(labels, value)
  end
  return outputter
end

function scraper_cpu()
  local stat = get_contents("/proc/stat")

  -- system boot time, seconds since epoch
  metric("node_boot_time", "gauge", nil, string.match(stat, "btime ([0-9]+)"))

  -- context switches since boot (all CPUs)
  metric("node_context_switches", "counter", nil, string.match(stat, "ctxt ([0-9]+)"))

  -- cpu times, per CPU, per mode
  local cpu_mode = {"user", "nice", "system", "idle", "iowait", "irq",
                    "softirq", "steal", "guest", "guest_nice"}
  local i = 0
  local cpu_metric = metric("node_cpu", "counter")
  while string.match(stat, string.format("cpu%d ", i)) do
    local cpu = space_split(string.match(stat, string.format("cpu%d ([0-9 ]+)", i)))
    local labels = {cpu = "cpu" .. i}
    for ii, mode in ipairs(cpu_mode) do
      labels['mode'] = mode
      cpu_metric(labels, cpu[ii] / 100)
    end
    i = i + 1
  end

  -- interrupts served
  metric("node_intr", "counter", nil, string.match(stat, "intr ([0-9]+)"))

  -- processes forked
  metric("node_forks", "counter", nil, string.match(stat, "processes ([0-9]+)"))

  -- processes running
  metric("node_procs_running", "gauge", nil, string.match(stat, "procs_running ([0-9]+)"))

  -- processes blocked for I/O
  metric("node_procs_blocked", "gauge", nil, string.match(stat, "procs_blocked ([0-9]+)"))
end

function scraper_load_averages()
  local loadavg = space_split(get_contents("/proc/loadavg"))

  metric("node_load1", "gauge", nil, loadavg[1])
  metric("node_load5", "gauge", nil, loadavg[2])
  metric("node_load15", "gauge", nil, loadavg[3])
end

function scraper_memory()
  local meminfo = line_split(get_contents("/proc/meminfo"):gsub("[):]", ""):gsub("[(]", "_"))

  for i, mi in ipairs(meminfo) do
    local name, size, unit = unpack(space_split(mi))
    if unit == 'kB' then
      size = size * 1024
    end
    metric("node_memory_" .. name, "gauge", nil, size)
  end
end

function scraper_file_handles()
  local file_nr = space_split(get_contents("/proc/sys/fs/file-nr"))

  metric("node_filefd_allocated", "gauge", nil, file_nr[1])
  metric("node_filefd_maximum", "gauge", nil, file_nr[3])
end

function scraper_network()
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
        metric("node_netstat_" .. nss .. "_" .. ss, "gauge", nil, substatv[ii])
      end
    end
  end
end

function scraper_network_devices()
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
    netdev_metric = metric("node_network_" .. ndss, "gauge")
    for ii, d in ipairs(devs) do
      netdev_metric({device=d}, nds_table[d][i])
    end
  end
end

function scraper_time()
  -- current time
  metric("node_time", "counter", nil, os.time())
end

function scraper_uname()
  -- version can have spaces, so grab it directly
  local version = string.sub(io.popen("uname -v"):read("*a"), 1, -2)
  -- avoid individual popen calls for the rest of the values
  local uname_string = io.popen("uname -a"):read("*a")
  local sysname, nodename, release = unpack(space_split(uname_string))
  local labels = {domainname = "(none)", nodename = nodename, release = release,
                  sysname = sysname, version = version}

  -- The machine hardware name is immediately after the version string, so add
  -- up the values we know and add in the 4 spaces to find the offset...
  machine_offset = string.len(sysname .. nodename .. release .. version) + 4
  labels['machine'] = string.match(string.sub(uname_string, machine_offset), "(%S+)" )
  metric("node_uname_info", "gauge", labels, 1)
end

function timed_scrape(scraper)
  local start_time = socket.gettime()
  -- build the function name and call it from global variable table
  _G["scraper_"..scraper]()
  local duration = socket.gettime() - start_time
  return duration
end

function run_all_scrapers()
  times = {}
  for i,scraper in ipairs(scrapers) do
    runtime = timed_scrape(scraper)
    times[scraper] = runtime
    scrape_time_sums[scraper] = scrape_time_sums[scraper] + runtime
    scrape_counts[scraper] = scrape_counts[scraper] + 1
  end

  local name = "node_exporter_scrape_duration_seconds"
  local duration_metric = metric(name, "summary")
  for i,scraper in ipairs(scrapers) do
    local labels = {collector=scraper, result="success"} 
    duration_metric(labels, times[scraper])
    print_metric(name.."_sum", labels, scrape_time_sums[scraper])
    print_metric(name.."_count", labels, scrape_counts[scraper])
  end
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
    run_all_scrapers()
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

scrape_counts = {}
scrape_time_sums = {}
for i,scraper in ipairs(scrapers) do
  scrape_counts[scraper] = 0
  scrape_time_sums[scraper] = 0
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
  run_all_scrapers()
end
