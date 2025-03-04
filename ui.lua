ui = {}

-- Prints an IRC command.
function ui.printcmd(rawline, ts, urgent_buf)
	local args = irc.parsecmd(rawline)
	local from = args.user
	local cmd = string.upper(args[1])
	local to = args[2] -- not always valid!
	local fmt = ui.ircformat

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
		msg = string.gsub(msg, nick_pattern(conn.user), hi(conn.user, true))

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
		if not config.left_margin then
			print(prefix .. userpart .. " " .. msg)
		else -- this is responsible for printing messages if the left_margin is enabled
			-- yeah it's spaghetti, 
			-- also i have no idea what 'notice' is so am copying that
			-- t. juspib
			if notice then
				userpart = string.format("-%s:%s-", hi(from), to)
			elseif action then
				local vislen = string.len(os.date(config.timefmt, ts))
				print(prefix .. string.rep(" ", config.left_margin_width - vislen -2 ) .. "\x1b[1m*\x1b[0m | " .. hi(from) .. " " .. msg)
			else
				local vislen = string.len(os.date(config.timefmt, ts)) + string.len(from) + 2
				if not (vislen > config.left_margin_width) then
					print(prefix .. string.rep(" ", config.left_margin_width - vislen -1) .. userpart  .. " | " .. msg)
				else
					print(prefix .. string.format("<%s>", hi(string.sub(from, 1, string.len(from)-(vislen-config.left_margin_width+1))).."+") .. "| " .. msg)
				end
			end
		end

		if private and not notice and from ~= conn.user then
			ui.hint(i18n.hint.query, from)
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

function ui.updateprompt()
	local chan = conn.chan or "nowhere"
	local unread, mentions = buffers:count_unread()
	capi.setprompt(string.format("[%d!%d %s]: ", unread, mentions, chan))
end

-- this mess isn't even correct. or at least it doesn't match up weechat's
-- settings quite right. 16+ should be correct, though.
local colormap = {
	[ 0] = 7,   [ 1] = 0,   [ 2] = 4,   [ 3] = 2,   [ 4] = 9,   [ 5] = 3,   
	[ 6] = 5,   [ 7] = 202, [ 8] = 11,  [ 9] = 10,  [10] = 6,   [11] = 14,  
	[12] = 12,  [13] = 13,  [14] = 8,   [15] = 7,   [16] = 52,  [17] = 94,  
	[18] = 100, [19] = 58,  [20] = 22,  [21] = 29,  [22] = 23,  [23] = 24,  
	[24] = 17,  [25] = 54,  [26] = 53,  [27] = 89,  [28] = 88,  [29] = 130, 
	[30] = 142, [31] = 64,  [32] = 28,  [33] = 35,  [34] = 30,  [35] = 25,  
	[36] = 18,  [37] = 91,  [38] = 90,  [39] = 125, [40] = 124, [41] = 166, 
	[42] = 184, [43] = 106, [44] = 34,  [45] = 49,  [46] = 37,  [47] = 33,  
	[48] = 19,  [49] = 129, [50] = 127, [51] = 161, [52] = 196, [53] = 208, 
	[54] = 226, [55] = 154, [56] = 46,  [57] = 86,  [58] = 51,  [59] = 75,  
	[60] = 21,  [61] = 171, [62] = 201, [63] = 198, [64] = 203, [65] = 215, 
	[66] = 227, [67] = 191, [68] = 83,  [69] = 122, [70] = 87,  [71] = 111, 
	[72] = 63,  [73] = 177, [74] = 207, [75] = 205, [76] = 217, [77] = 223, 
	[78] = 229, [79] = 193, [80] = 157, [81] = 158, [82] = 159, [83] = 153, 
	[84] = 147, [85] = 183, [86] = 219, [87] = 212, [88] = 16,  [89] = 233, 
	[90] = 235, [91] = 237, [92] = 239, [93] = 241, [94] = 244, [95] = 247, 
	[96] = 250, [97] = 254, [98] = 231, 
}

-- format irc messages for display, escaping unknown characters
-- https://modern.ircdocs.horse/formatting.html
function ui.ircformat(s)
	-- DON'T USE \x1b[0m unless you're absolutely sure. check the correct code
	-- see tsetattr in http://git.suckless.org/st/file/st.c.html

	local function t(cur, enable, disable) -- toggle
		if cur then
			return false, disable
		else
			return true, enable
		end
	end

	local function color(fg, bg)
		if not config.color.in_messages then
			return ""
		end

		local function get_fg(fg)
			if not fg then return "" end
			fg = tonumber(fg)
			if fg == 99 then
				return "\x1b[39m" -- reset
			else
				return string.format("\x1b[38;5;%sm", colormap[fg])
			end
		end
		local function get_bg(bg)
			if not bg then return "" end
			bg = tonumber(bg)
			if bg == 99 then
				return "\x1b[49m" -- reset
			else
				return string.format("\x1b[48;5;%sm", colormap[bg])
			end
		end
		return get_fg(fg) .. get_bg(bg)
	end

	local bold, italic, underline, reverse

	s = string.gsub(s, "[\x00-\x1F\x7F]", function (c)
		local r -- replacement

		if c == "\x02" then
			bold, r = t(bold, "\x1b[1m", "\x1b[22m")
		elseif c == "\x03" then
			-- color handling is a special beast. leave it for later
			return c
		elseif c == "\x1d" then
			italic, r = t(italic, "\x1b[3m", "\x1b[23m")
		elseif c == "\x1f" then
			underline, r = t(underline, "\x1b[4m", "\x1b[24m")
		elseif c == "\x16" then
			reverse, r = t(reverse, "\x1b[7m", "\x1b[27m")
		elseif c == "\x0F" then
			r = "\x1b[m"
			bold = false
			italic = false
			underline = false
			reverse = false
		end

		return r or ui.escape_char(c)
	end)

	s = string.gsub(s, "\x03([0-9][0-9]?),([0-9][0-9]?)", color)
	s = string.gsub(s, "\x03([0-9][0-9]?)", color)
	s = string.gsub(s, "\x03", "\x1b[39m\x1b[49m")

	if string.find(s, "\x1b") then s = s.."\x1b[m" end -- reset if needed
	return s
end

-- https://en.wikipedia.org/wiki/Caret_notation
-- meant to be used as an argument to string.gsub
function ui.escape_char(c)
	local b = string.byte(c)
	if b < 0x20 or b == 0x7F then
		return "\x1b[7m^"..string.char(b ~ 64).."\x1b[27m"
	end
	return c
end

-- escape non-utf8 chars
function ui.escape(s)
	s = string.gsub(s, "[\x00-\x1F\x7F]", ui.escape_char)
	return s
end

function ui.strip_ansi(s)
	return string.gsub(s, "\x1b%[[^\x40-\x7E]*[\x40-\x7E]", "")
end

local used_hints = {}
function ui.hint(s, ...)
	if not used_hints[s] then
		printf(s, ...)
		used_hints[s] = true
	end
end
