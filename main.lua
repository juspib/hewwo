-- "capi" is provided by C
require "tests"
require "util"
require "irc"
require "commands"
require "buffers"
require "i18n"
-- also see eof

-- for functions called by C
cback = {}

conn = {
	user = nil,
	nick_verified = false,
	nick_idx = 1, -- for the initial nick
	-- i don't care if the nick gets ugly, i need to connect ASAP to prevent
	-- the connection from dropping

	chan = nil,
}


-- The whole external program piping shebang.
-- Basically: if an external program is launched, print() should
--            either buffer up the input to show later, or pipe it
--            to the program.
ext = {}
ext.running = false
ext.ringbuf = nil
ext._pipe = false
ext.reason = nil
ext.eof = capi.ext_eof
function print(...)
	if ext.running then
		if ext._pipe then
			local args = {...}
			for k,v in ipairs(args) do
				if type(v) == "string" then
					args[k] = ansi_strip(v)
				end
			end
			capi.print_internal(table.unpack(args))
		else
			ext.ringbuf:push({...})
		end
	else
		capi.print_internal(...)
	end
end

function ext.run(cmdline, reason)
	if ext.running then return end
	ext.running = true
	ext.ringbuf = ringbuf:new(500)
	capi.ext_run_internal(cmdline)
	ext._pipe = false
	ext.reason = reason
end

-- true:  print()s should be passed to the external process
-- false: print()s should be cached until the ext process quits
function ext.setpipe(b)
	ext._pipe = b
end

function cback.ext_quit()
	ext.running = false
	-- TODO notify the user if the ringbuf overflowed
	capi.print_internal("printing the messages you've missed...")
	for v in ext.ringbuf:iter(ext.ringbuf) do
		capi.print_internal(table.unpack(v))
	end
	ext.ringbuf = nil
	ext.reason = nil
end


function cback.init(...)
	local argv = {...}
	local host = argv[2] or "localhost"
	local port = argv[3] or "6667"
	if not capi.dial(host, port) then
		printf("couldn't connect to %s:%s :(", host, port)
		os.exit(1)
	end

	local default_name = os.getenv("USER") or "townie"
	config.nick = config.nick or default_name -- a hack
	conn.user = config.nick
	printf(i18n.connecting, hi(conn.user))
	writecmd("USER", config.ident.username or default_name, "0", "*",
	                 config.ident.realname or default_name)
	writecmd("NICK", conn.user)
	capi.history_resize(config.history_size)

	conn.chan = nil

	buffers:make(":mentions")
	buffers.tbl[":mentions"].printcmd = function (self, ent)
		printcmd(ent.line, ent.ts, ent.buf)
	end
	buffers.tbl[":mentions"].onswitch = function (self)
		for k,v in pairs(buffers.tbl) do
			v.mentions = 0
		end
	end
end

function cback.disconnected()
	-- TODO do something reasonable
	print([[you got disconnected from the server :/]])
	print([[restart hewwo with "/QUIT" to reconnect]])
end

function cback.in_net(line)
	if config.debug then
		print("<=", escape(line))
	end
	newcmd(line, true)
	updateprompt()
end

function cback.in_user(line)
	if line == "" then return end
	if line == nil then
		hint(i18n.quit_hint)
		return
	end
	capi.history_add(line)

	if string.sub(line, 1, 1) == "/" then
		if string.sub(line, 2, 2) == "/" then
			line = string.sub(line, 2)
			writecmd("PRIVMSG", conn.chan, line)
		else
			local args = cmd_parse(line)
			local cmd = commands[string.lower(args[0])]
			if cmd then
				cmd(line, args)
			else
				print("unknown command \"/"..args[0].."\"")
			end
		end
	elseif conn.chan then
		if string.sub(conn.chan, 1, 1) == ":" then
			printf(i18n.err_rochan, conn.chan)
		else
			writecmd("PRIVMSG", conn.chan, line)
		end
	else
		print(i18n.err_nochan)
	end
	updateprompt()
end

-- Called for new commands, both from the server and from the client.
function newcmd(line, remote)
	local args = parsecmd(line)
	local from = args.user
	local cmd = string.upper(args[1])
	local to = args[2] -- not always valid!

	if not remote and not (cmd == "PRIVMSG" or cmd == "NOTICE") then
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
				writecmd("NOTICE", from, "\1VERSION hewwo\1")
			elseif args.ctcp.cmd == "PING" then
				writecmd("NOTICE", from, args[3])
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
			printcmd(line, os.time())
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
			printcmd(line, os.time())
		end
		for chan,buf in pairs(buffers.tbl) do
			if buf.users[from] then
				buffers:push(chan, line, {display=display, urgency=-1})
				buf.users[from] = nil
				buf.users[to] = true
			end
		end
	elseif cmd == RPL_ENDOFMOTD or cmd == ERR_NOMOTD then
		conn.nick_verified = true
		print(i18n.connected)
		print()
	elseif cmd == RPL_TOPIC then
		buffers:push(args[3], line)
	elseif cmd == "TOPIC" then
		local display = 0
		if from == conn.user then display = 1 end
		buffers:push(to, line, {display=display})
	elseif cmd == RPL_LIST or cmd == RPL_LISTEND then
		-- TODO list output should probably be pushed into a server buffer
		-- but switching away from the current buffer could confuse users?

		if ext.reason == "list" then ext.setpipe(true) end
		printcmd(line, os.time())
		if ext.reason == "list" then ext.setpipe(false) end
	elseif cmd == ERR_NICKNAMEINUSE then
		if conn.nick_verified then
			printf("%s is taken, leaving your nick as %s", hi(args[3]), hi(conn.user))
		else
			local new = config.nick .. conn.nick_idx
			conn.nick_idx = conn.nick_idx + 1
			printf("%s is taken, trying %s", hi(conn.user), hi(new))
			conn.user = new
			writecmd("NICK", new)
		end
	elseif string.sub(cmd, 1, 1) == "4" then
		-- TODO the user should never see this. they should instead see friendlier
		-- messages with instructions how to proceed
		printf("irc error %s: %s", cmd, args[#args])
	elseif cmd == "PING" then
		writecmd("PONG", to)
	elseif cmd == RPL_NAMREPLY then
		to = args[4]
		buffers:make(to)
		-- TODO incorrect nick parsing
		for nick in string.gmatch(args[5], "[^ ,*?!@]+") do
			buffers.tbl[to].users[nick] = true
		end
	end
end

function cback.completion(line)
	local tbl = {}
	local word = string.match(line, "[^ ]*$") or ""
	if word == "" then return {} end
	local wlen = string.len(word)
	local rest = string.sub(line, 1, -string.len(word)-1)

	local function addfrom(src, prefix, suffix)
		if not src then return end
		prefix = prefix or ""
		suffix = suffix or " "
		local wlen = string.len(word)
		for k, v in pairs(src) do
			k = prefix..k..suffix
			if v and wlen < string.len(k) and word == string.sub(k, 1, wlen) then
				table.insert(tbl, rest..k)
			end
		end
	end

	local buf = buffers.tbl[conn.chan]
	if buf then
		if word == line then
			addfrom(buf.users, "", ": ")
		else
			addfrom(buf.users)
		end
	end
	addfrom(buffers.tbl)
	addfrom(commands, "/")
	return tbl
end

function updateprompt()
	local chan = conn.chan or "nowhere"
	local unread, mentions = buffers:count_unread()
	capi.setprompt(string.format("[%d!%d %s]: ", unread, mentions, chan))
end

-- Prints an IRC command.
function printcmd(rawline, ts, urgent_buf)
	local args = parsecmd(rawline)
	local from = args.user
	local cmd = string.upper(args[1])
	local to = args[2] -- not always valid!
	local fmt = ircformat

	local clock = os.date(config.timefmt, ts)
	if config.color.clock then
		-- wrap the clock in ANSI color codes iff the user specified a color
		clock = string.format("\x1b[%sm%s\x1b[0m", config.color.clock, clock)
	end

	local prefix = clock
	if urgent_buf then
		prefix = string.format("%s%s: ", prefix, urgent_buf)
	end

	if cmd == "PRIVMSG" or cmd == "NOTICE" then
		local action = false
		local private = false
		local notice = cmd == "NOTICE"

		local userpart = ""
		local msg = args[3]

		if string.sub(to, 1, 1) ~= "#" then
			private = true
		end
		if args.ctcp and args.ctcp.cmd == "ACTION" then
			action = true
			msg = args.ctcp.params
		end

		msg = fmt(msg)
		-- highlight own nick
		msg = string.gsub(msg, nick_pattern(conn.user), hi(conn.user))

		if private then
			-- the original prefix might also include the buffer,
			-- which is redundant
			prefix = clock

			if notice then
				userpart = string.format("-%s:%s-", hi(from), hi(to))
			elseif action then
				userpart = string.format("[%s -> %s] * %s", hi(from), hi(to), hi(from))
			else
				userpart = string.format("[%s -> %s]", hi(from), hi(to))
			end
		else
			if notice then
				userpart = string.format("-%s:%s-", hi(from), to)
			elseif action then
				userpart = string.format("* %s", hi(from))
			else
				userpart = string.format("<%s>", hi(from))
			end
		end
		print(prefix .. userpart .. " " .. msg)

		if private and not notice and from ~= conn.user then
			hint(i18n.query_hint, from)
		end
	elseif cmd == "JOIN" then
		printf("%s--> %s has joined %s", prefix, hi(from), to)
	elseif cmd == "PART" then
		printf("%s<-- %s has left %s", prefix, hi(from), to)
	elseif cmd == "KICK" then
		printf("%s-- %s kicked %s from %s (%s)", prefix, hi(from), hi(args[3]), args[2], args[4] or "")
	elseif cmd == "INVITE" then
		printf("%s%s has invited you to %s", prefix, hi(from), args[3])
	elseif cmd == "QUIT" then
		printf("%s<-- %s has quit (%s)", prefix, hi(from), fmt(args[2]))
	elseif cmd == "NICK" then
		printf("%s%s is now known as %s", prefix, hi(from), hi(to))
	elseif cmd == RPL_TOPIC then
		printf([[%s-- %s's topic is "%s"]], prefix, args[3], fmt(args[4]))
	elseif cmd == "TOPIC" then
		-- TODO it'd be nice to store the old topic
		printf([[%s%s set %s's topic to "%s"]], prefix, from, to, fmt(args[3]))
	elseif cmd == RPL_LIST then
		if ext.reason == "list" then
			prefix = "" -- don't include the hour
		end
		if args[5] ~= "" then
			printf([[%s%s, %s users, %s]], prefix, args[3], args[4], fmt(args[5]))
		else
			printf([[%s%s, %s users]], prefix, args[3], args[4])
		end
	elseif cmd == RPL_LISTEND then
		printf(i18n.list_after)
		ext.eof()
	else
		-- TODO config.debug levels
		printf([[error in hewwo: printcmd can't handle "%s"]], cmd)
	end
end

config = {}
config.ident = {}
config.color = {}
require "config_default"
require "config" -- last so as to let it override stuff
