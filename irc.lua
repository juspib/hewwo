RPL_LIST = "322"
RPL_LISTEND = "323"
RPL_TOPIC = "332"
RPL_NAMREPLY = "353"
RPL_ENDOFMOTD = "376"
ERR_NOMOTD = "422"
ERR_NICKNAMEINUSE = "433"

irc = {}

function irc.writecmd(...)
	local cmd = ""
	-- TODO enforce no spaces
	for i, v in ipairs({...}) do
		if i ~= 1 then
			cmd = cmd .. " "
			if i == #{...} then
				cmd = cmd .. ":"
			end
		end
		cmd = cmd .. v
	end

	if config.debug then
		print("=>", ui.escape(cmd))
	end
	capi.writesock(cmd)
	irc.newcmd(":"..conn.user.."!@ "..cmd, false)
end

function irc.parsecmd(line)
	local data = {}

	local pos = 1
	if string.sub(line, 1, 1) == ":" then
		pos = string.find(line, " ")
		if not pos then return end -- invalid message
		data.prefix = string.sub(line, 2, pos-1)
		pos = pos+1

		excl = string.find(data.prefix, "!")
		if excl then
			data.user = string.sub(data.prefix, 1, excl-1)
		end
	end
	while pos <= string.len(line) do
		local nextpos = nil
		if string.sub(line, pos, pos) ~= ":" then
			nextpos = string.find(line, " ", pos+1)
		else
			pos = pos+1
		end
		if not nextpos then
			nextpos = string.len(line)+1
		end
		table.insert(data, string.sub(line, pos, nextpos-1))
		pos = nextpos+1
	end

	local cmd = string.upper(data[1])
	if (cmd == "PRIVMSG" or cmd == "NOTICE") and string.sub(data[3], 1, 1) == "\1" then
		data.ctcp = {}
		local inner = string.gsub(string.sub(data[3], 2), "\1$", "")
		local split = string.find(inner, " ", 2)
		if split then
			data.ctcp.cmd = string.upper(string.sub(inner, 1, split-1))
			data.ctcp.params = string.sub(inner, split+1)
		else
			data.ctcp.cmd = string.upper(inner)
		end
	end

	return data
end

-- Called for new commands, both from the server and from the client.
function irc.newcmd(line, remote)
	local args = irc.parsecmd(line)
	local from = args.user
	local cmd = string.upper(args[1])
	local to = args[2] -- not always valid!

	if not remote and not (cmd == "PRIVMSG" or cmd == "NOTICE" or cmd == "QUIT") then
		-- (afaik) all other messages are echoed back at us
		return
	end

	if cmd == "PRIVMSG" or cmd == "NOTICE" then
		-- TODO strip first `to` character for e.g. +#tildetown
		if to == "*" then return end

		if not args.ctcp or args.ctcp.cmd == "ACTION" then
			-- TODO factor out dm checking for consistency
			if to == conn.user then -- direct message
				buffers:push(from, line, {urgency=1})
			else
				local msg
				if not args.ctcp then
					msg = args[3]
				else
					msg = args.ctcp.params or ""
				end

				if string.match(msg, nick_pattern(conn.user)) then
					buffers:push(to, line, {urgency=2})
				elseif from == conn.user then
					buffers:push(to, line, {urgency=1})
				else
					buffers:push(to, line)
				end
			end
		end

		if cmd == "PRIVMSG" and args.ctcp and remote then
			if args.ctcp.cmd == "VERSION" then
				irc.writecmd("NOTICE", from, "\1VERSION hewwo\1")
			elseif args.ctcp.cmd == "PING" then
				irc.writecmd("NOTICE", from, args[3])
			end
		end
	elseif cmd == "JOIN" then
		buffers:push(to, line, {urgency=-1})
		if from == conn.user then
			buffers.tbl[to].connected = true
		end
		buffers.tbl[to].users[from] = true
	elseif cmd == "PART" then
		buffers:push(to, line, {urgency=-1})
		buffers:leave(to, from)
	elseif cmd == "KICK" then
		buffers:push(to, line)
		buffers:leave(to, args[3])
	elseif cmd == "INVITE" then
		buffers:push(from, line, {urgency=2})
	elseif cmd == "QUIT" then
		local display = 0
		if from == conn.user then
			-- print manually
			display = -1
			ui.printcmd(line, os.time())
		end
		for chan,buf in pairs(buffers.tbl) do
			if buf.users[from] then
				buffers:push(chan, line, {display=display, urgency=-1})
				buf.users[from] = nil
			end
		end
	elseif cmd == "NICK" then
		local display = 0
		if from == conn.user then
			conn.user = to
			-- print manually
			display = -1
			ui.printcmd(line, os.time())
		end
		for chan,buf in pairs(buffers.tbl) do
			if buf.users[from] then
				buffers:push(chan, line, {display=display, urgency=-1})
				buf.users[from] = nil
				buf.users[to] = true
			end
		end
	elseif cmd == RPL_ENDOFMOTD or cmd == ERR_NOMOTD then
		conn.active = true
		print(i18n.connected)
		print()
	elseif cmd == RPL_TOPIC then
		buffers:push(args[3], line, {urgency=-1})
	elseif cmd == "TOPIC" then
		local display = 0
		if from == conn.user then display = 1 end
		buffers:push(to, line, {display=display})
	elseif cmd == RPL_LIST or cmd == RPL_LISTEND then
		-- TODO list output should probably be pushed into a server buffer
		-- but switching away from the current buffer could confuse users?

		if ext.reason == "list" then ext.setpipe(true) end
		ui.printcmd(line, os.time())
		if ext.reason == "list" then ext.setpipe(false) end
	elseif cmd == ERR_NICKNAMEINUSE then
		if conn.active then
			printf("%s is taken, leaving your nick as %s", hi(args[3]), hi(conn.user))
		else
			local new = config.nick .. conn.nick_idx
			conn.nick_idx = conn.nick_idx + 1
			printf("%s is taken, trying %s", hi(conn.user), hi(new))
			conn.user = new
			irc.writecmd("NICK", new)
		end
	elseif string.sub(cmd, 1, 1) == "4" then
		-- TODO the user should never see this. they should instead see friendlier
		-- messages with instructions how to proceed
		printf("irc error %s: %s", cmd, args[#args])
	elseif cmd == "PING" then
		irc.writecmd("PONG", to)
	elseif cmd == RPL_NAMREPLY then
		to = args[4]
		buffers:make(to)
		-- TODO incorrect nick parsing
		for nick in string.gmatch(args[5], "[^ ,*?!@]+") do
			buffers.tbl[to].users[nick] = true
		end
	end
end
