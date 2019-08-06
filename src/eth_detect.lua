require 'muhkuh_cli_init'
local uv = require 'lluv'

local strRomloaderMagic = string.char(0x00, 0x4d, 0x4f, 0x4f, 0x48, 0x00, 0x00, 0x01, 0x00, 0x00, 0x04)

-- Read the boot image.
local strBootImageFilename = 'activate_eth0_boot.img'
local tFile, strError = io.open(strBootImageFilename, 'rb')
if tFile==nil then
  print('Failed to read "' .. strBootImageFilename ..'": ' .. tostring(strError))
  error('Missing bootimage.')
end
local strBootImage = tFile:read('*a')
tFile:close()
-- Prepare the size for the boot image.
local sizBootImage = string.len(strBootImage)
local sizBootImageLo = sizBootImage & 0x00ff
local sizBootImageHi = (sizBootImage & 0xff00) >> 8


local BOOTSTATE_ReadId0 = 0
local BOOTSTATE_ReadId1 = 1
local BOOTSTATE_ReadId2 = 2
local BOOTSTATE_WriteData = 3
local BOOTSTATE_Finished = 4
local BOOTSTATE_Error   = -1

local atDetectedNetx = {}

local function on_write(cli, err)
  if err then
    print("WRITE ERROR: ", err)
    return cli:close()
  end
end

local function getData32(strData, uiOffset)
  return string.byte(strData, uiOffset) + 0x00000100*string.byte(strData, uiOffset+1) + 0x00010000*string.byte(strData, uiOffset+2) + 0x01000000*string.byte(strData, uiOffset+3)
end

local function on_read(tSocket, err, strData, flags, strHost, usPort)
  if err then
    print("READ ERROR: ", err)
    return tSocket:close()
  end

  local sizData = string.len(strData)
  print(string.format('Received %d bytes from %s:%d', sizData, strHost, usPort))

  -- All netX communication comes from port 53280.
  if usPort==53280 then
    -- Is this a magic mooh packet?
    if sizData==15 and string.sub(strData, 1, 11)==strRomloaderMagic then
      -- Yes, it is. Extract the IP.
      local strHostHBoot = string.format('%d.%d.%d.%d', string.byte(strData, 15), string.byte(strData, 14), string.byte(strData, 13), string.byte(strData, 12))
      if strHost==strHostHBoot then
        -- Is the IP already part of the list?
        local tAttr = atDetectedNetx[strHost]
        if tAttr==nil then
          print(string.format('Found a new netX4000 at %s', strHost))
          -- Create a new entry.
          tAttr = {
            fIsStillThere = true,
            tState = BOOTSTATE_ReadId0
          }
          atDetectedNetx[strHost] = tAttr

          -- Send the first ID request.
          tSocket:send(strHost, 53280, string.char(0x80, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00))
        else
          print(string.format('netX4000 is still at %s', strHost))
          tAttr.fIsStillThere = true
        end
      else
        print(string.format('UDP IP does not match HBOOT IP: %s/%s.', strHost, strHostHBoot))
      end

    else
      -- Is the IP already in the list of known devices?
      local tAttr = atDetectedNetx[strHost]
      if tAttr~=nil then
        local tState = tAttr.tState
        if tState==BOOTSTATE_ReadId0 then
          -- This is the response to read ID 0.
          -- Is the status "OK"?
          local ucStatus = string.byte(strData, 1)
          if ucStatus==0 and sizData==5 then
            -- Get the response.
            local ulData = getData32(strData, 2)
            if ulData==0xe59ff00c then
              tAttr.tState = BOOTSTATE_ReadId1
              tSocket:send(strHost, 53280, string.char(0x80, 0x04, 0x00, 0x20, 0x00, 0x10, 0x04))
            else
              print(string.format('Unknown ID0: 0x%08x\n', ulData))
              tAttr.tState = BOOTSTATE_Error
            end
          else
            -- This is an error.
            print('Invalid response in ReadId0.')
            tAttr.tState = BOOTSTATE_Error
          end

        elseif tState==BOOTSTATE_ReadId1 then
          -- This is the response to read ID 1.
          -- Is the status "OK"?
          local ucStatus = string.byte(strData, 1)
          if ucStatus==0 and sizData==5 then
            -- Get the response.
            local ulData = getData32(strData, 2)
            if ulData==0x0010b004 then
              tAttr.tState = BOOTSTATE_ReadId2
              tSocket:send(strHost, 53280, string.char(0x80, 0x04, 0x00, 0xc0, 0x00, 0x00, 0xf8))
            else
              print(string.format('Unknown ID1: 0x%08x\n', ulData))
              tAttr.tState = BOOTSTATE_Error
            end
          else
            -- This is an error.
            print('Invalid response in ReadId1.')
            tAttr.tState = BOOTSTATE_Error
          end

        elseif tState==BOOTSTATE_ReadId2 then
          -- This is the response to read ID 2.
          -- Is the status "OK"?
          local ucStatus = string.byte(strData, 1)
          if ucStatus==0 and sizData==5 then
            -- Get the response.
            local ulData = getData32(strData, 2)
            if ulData==0xe0000010 then
              tAttr.tState = BOOTSTATE_WriteData
              local strPacket = string.char(0x01, sizBootImageLo, sizBootImageHi, 0x00, 0x00, 0x10, 0x05) .. strBootImage
              tSocket:send(strHost, 53280, strPacket)
            else
              print(string.format('Unknown ID2: 0x%08x\n', ulData))
            end
          else
            -- This is an error.
            print('Invalid response in ReadId2.')
            tAttr.tState = BOOTSTATE_Error
          end

        elseif tState==BOOTSTATE_WriteData then
          -- This is the response to the "write data" packet.
          -- Is the status "OK"?
          local ucStatus = string.byte(strData, 1)
          if ucStatus==0 and sizData==1 then
            tAttr.tState = BOOTSTATE_Finished
            tSocket:send(strHost, 53280, string.char(0x02, 0x7d, 0x5c, 0x11, 0x04, 0x00, 0x00, 0x00, 0x00))
          else
            -- This is an error.
            print('Invalid response in WriteData.')
            tAttr.tState = BOOTSTATE_Error
          end

        else
          print('Invalid packet')
        end
      end
    end
  else
    print('Invalid port: ' .. usPort)
  end
end


local function onScanTimer(tTimer, tSocket)
  -- Remove all devices which are still undetected.
  for strIp, tAttr in pairs(atDetectedNetx) do
    if tAttr.fIsStillThere==false then
      -- Remove the entry.
      atDetectedNetx[strIp] = nil
    end
  end

  -- Now set all devices to "undetected".
  for uiIndex, tAttr in pairs(atDetectedNetx) do
    tAttr.fIsStillThere = false
  end
  -- Send a "hello" packet.
  tSocket:send('224.0.0.251', 53280, 'hello')

  tTimer:again(1000)
end

-- Create a socket.
local tSock = uv.udp():bind('192.168.64.1', 0)
-- tSock:start_recv(function(tSocket, tError, tData, tFlags, tHost, tPort) on_read(
tSock:start_recv(on_read)

-- Scan for new servers all 5 seconds.
local tScanTimer = uv.timer():start(1000, function(tTimer) onScanTimer(tTimer, tSock) end)

uv.run()
