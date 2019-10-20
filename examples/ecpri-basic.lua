local mg     = require "moongen"
local memory = require "memory"
local device = require "device"
local ts     = require "timestamping"
local stats  = require "stats"
local hist   = require "histogram"
local proto  = require "proto.proto"

local PKT_SIZE	= 60
local ETH_DST	= "3c:fd:fe:ad:84:a5"
local ETH_SRC	= "3c:fd:fe:bc:db:f9"

local function getRstFile(...)
	local args = { ... }
	for i, v in ipairs(args) do
		result, count = string.gsub(v, "%-%-result%=", "")
		if (count == 1) then
			return i, result
		end
	end
	return nil, nil
end

function configure(parser)
	parser:description("Generates eCPRI traffic from SRC to DST with hardware rate control and measure latencies.")
	parser:argument("eRE", "Device to transmit from."):convert(tonumber)
	parser:argument("eREC", "Device to receive from."):convert(tonumber)
	parser:option("-r --rate", "Transmit rate in Mbit/s."):default(10000):convert(tonumber)
	parser:option("-s --size", "Packet size."):default(60):convert(tonumber)
	parser:option("-f --file", "Filename of the latency histogram."):default("histogram.csv")
end

function master(args)
	local eRE = device.config({port = args.eRE, rxQueues = 2, txQueues = 2})
	local eREC = device.config({port = args.eREC, rxQueues = 2, txQueues = 2})
	device.waitForLinks()
	if args.rate > 0 then
		eRE:getTxQueue(0):setRate(args.rate)
	end 
	-- eREC:getTxQueue(0):setRate(args.rate)
	mg.startTask("loadSlave", eRE:getTxQueue(0), args.size)
	-- if eRE ~= eREC then
	--	mg.startTask("timerSlave", eREC:getTxQueue(1), eREC:getRxQueue(1), args.size, args.file)
	-- end
	stats.startStatsTask{eRE}
	-- mg.startSharedTask("timerSlave", eRE:getTxQueue(1), eREC:getRxQueue(1), args.file)
	mg.waitForTasks()
end

local function fillEcpriPacket(buf, len)
--	print(tostring(len))
	buf:getEcpriPacket():fill{
		ethSrc = queue,
		ethDst = ETH_DST,
		ethType = proto.eth.TYPE_ECRPI,
		payloadLength = len,
	}
end


function loadSlave(queue, size)
	print(tostring(size))
	local mem = memory.createMemPool(function(buf)
		fillEcpriPacket(buf, size)
	end)
	local bufs = mem:bufArray()
	while mg.running() do
		bufs:alloc(PKT_SIZE)
		queue:send(bufs)
	end
end

function timerSlave(txQueue, rxQueue, size, histfile) 
	local timestamper = ts:newTimestamper(txQueue, rxQueue)
	local hist = hist:new()
	mg.sleepMillis(1000) -- ensure that the load task is running
	while mg.running() do
		hist:update(timestamper:measureLatency(function(buf) buf:getEthernetPacket().eth.dst:setString(ETH_DST) end))
	end
	hist:print()
	hist:save(histfile)
end

