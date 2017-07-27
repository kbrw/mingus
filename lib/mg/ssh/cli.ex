defmodule Mg.SSH.Cli do
  @moduledoc """
  Inspired by ssh_cli
  """
  require Logger

  alias Mg.SSH.Connection
  alias Mg.SSH.GitCmd
  alias Mg.SSH.Cli
  alias Mg.SSH.Pty
  alias OCCI.Store

  @behaviour :ssh_channel

  defstruct channel: nil, cm: nil, infos: nil, user: nil, pty: nil, buf: nil, worker: nil, worker_mod: nil
  @kind_user :"http://schemas.ogf.org/occi/auth#user"

  ###
  ### Callbacks
  ###
  def init(_opts) do
    {:ok, %Cli{}}
  end

  def terminate(_reason, _state) do
    :ok
  end

  def handle_call(_msg, _from, s) do
    {:reply, :ok, s}
  end

  def handle_cast(_msg, s) do
    {:noreply, s}
  end

  ###
  ### Data events
  ###
  def handle_ssh_msg({:ssh_cm, cm,
                      {:data, channelId, _dataTypeCode, data}},
    %Cli{ cm: cm, channel: channelId, worker: worker, worker_mod: mod }=s) do
    mod.data(worker, String.to_charlist(data))
    {:ok, s}
  end
  def handle_ssh_msg({:ssh_cm, cm,
                      {:eof, channelId}},
    %Cli{ cm: cm, channel: channelId }=s) do
    {:ok, s}
  end

  ###
  ### Status events
  ###
  def handle_ssh_msg({:ssh_cm, cm,
                      {:signal, channelId, _signal}},
    %Cli{ cm: cm, channel: channelId }=s) do
    # Ignore signals according to RFC 4254 section 6.9.
    {:ok, s}
  end
  def handle_ssh_msg({:ssh_cm, cm,
                      {:exit_signal, channelId, _exitSignal, exitMsg, _languageString}},
    %Cli{ cm: cm, channel: channelId }=s) do
    Logger.error("Connection closed by peer: #{exitMsg}")
    {:stop, channelId, s}
  end
  def handle_ssh_msg({:ssh_cm, cm,
                      {:exit_status, channelId, 0}},
    %Cli{ cm: cm, channel: channelId }=s) do
    Logger.error("Connection closed: logout")
    {:stop, channelId, s}
  end
  def handle_ssh_msg({:ssh_cm, cm,
                      {:exit_status, channelId, status}},
    %Cli{ cm: cm, channel: channelId }=s) do
    Logger.error("Connection closed by peer: status=#{status}")
    {:stop, channelId, s}
  end

  ###
  ### Terminal events
  ###
  def handle_ssh_msg({:ssh_cm, cm,
                      {:env, channelId, wantReply, var, value}},
    %Cli{ cm: cm, channel: channelId }=s) do
    Logger.debug("<ssh> env #{var}=#{value}")
    Connection.reply(s, :failure, wantReply)
    {:ok, s}
  end
  def handle_ssh_msg({:ssh_cm, cm,
                      {:pty, channelId, wantReply, {termName, width, height, pixWidth, pixHeight, modes}}},
    %Cli{ cm: cm, channel: channelId }=s) do
    Logger.debug("<ssh> pty #{termName}...")
    pty = %Pty{ term: termName,
                width: not_zero(width, 80), height: not_zero(height, 24),
                pixelWidth: pixWidth, pixelHeight: pixHeight,
                modes: modes }
    set_echo(s)
    Connection.reply(s, :success, wantReply)
    {:ok, %Cli{ s | pty: pty, buf: empty_buf() }}
  end
  def handle_ssh_msg({:ssh_cm, cm,
                      {:window_change, channelId, width, height, pixWidth, pixHeight}=msg},
    %Cli{ cm: cm, channel: channelId, pty: pty0, buf: buf }=s) do
    Logger.debug("<ssh> window_change: #{inspect msg}")
    pty = %Pty{ pty0 | width: width, height: height, pixelWidth: pixWidth, pixelHeight: pixHeight }
    {chars, buf} = io_request({:window_change, pty0}, buf, pty, nil)
    Connection.write_chars(s, chars)
    {:ok, %Cli{ pty: pty, buf: buf }}
  end
  def handle_ssh_msg({:ssh_cm, cm,
                      {:shell, channelId, wantReply}},
    %Mg.SSH.Cli{ cm: cm, channel: channelId }=s) do
    Logger.debug("<ssh> shell")
    s = start_shell(s)
    Connection.reply(s, :success, wantReply)
    {:ok, s}
  end
  def handle_ssh_msg({:ssh_cm, cm,
                      {:exec, channelId, wantReply, cmd}},
    %Mg.SSH.Cli{ cm: cm, channel: channelId }=s) do
    Logger.debug("<ssh> exec: #{cmd}")
    case exec(s, "#{cmd}") do
      {status, s} ->
        Connection.reply(s, status, wantReply)
        {:ok, s}
      {status, msg, s} ->
        Connection.reply(s, status, wantReply, "\n#{msg}\n\n")
        {:ok, s}
    end
  end

  ###
  ### Handle other channel messages
  ###
  def handle_msg({:ssh_channel_up, channelId, connRef}, _) do
    infos = Connection.infos(connRef)
    [user] = Store.lookup([kind: @kind_user, "occi.auth.login": "#{infos.user}"])
    {:ok, %Cli{ channel: channelId, cm: connRef, infos: infos, user: user }}
  end
  def handle_msg({group, :set_unicode_state, _arg}, s) do
    send(group, {self(), :set_unicode_state, false})
    {:ok, s}
  end
  def handle_msg({group, :get_unicode_state}, s) do
    send(group, {self(), :get_unicode_state, false})
    {:ok, s}
  end
  def handle_msg({group, :tty_geometry}, %Cli{ worker: group, pty: pty }=s) do
    case pty do
      %Pty{ width: width, height: height } ->
        send(group, {self(), :tty_geometry, {width, height}})
      _ ->
        # This is a dirty fix of the problem with the otp ssh:shell
	      # client. That client will not allocate a tty, but someone
	      # asks for the tty_geometry just before every erlang prompt.
	      # If that question is not answered, there is a 2 sec timeout
	      # Until the prompt is seen by the user at the client side ...
	      send(group, {self(), :tty_geometry, {0,0}})
    end
    {:ok, s}
  end
  def handle_msg({group, req}, %Cli{ worker: group, buf: buf, pty: pty }=s) do
    {chars, buf} = io_request(req, buf, pty, group)
    Connection.write_chars(s, chars)
    {:ok, %Cli{ s | buf: buf }}
  end
  def handle_msg({:EXIT, pid, reason}, %Cli{ worker: pid, channel: channelId }=s) do
    Connection.exit_status(s, case reason do
                                :normal -> 0
                                _ -> -1
                              end)
    Connection.send_eof(s)
    {:stop, channelId, s}
  end
  def handle_msg(_, s) do
    {:ok, s}
  end

  def code_change(_oldvsn, s, _extra) do
    {:ok, s}
  end

  ###
  ### Private
  ###
  defp exec(%Cli{}=s, "git-receive-pack " <> _ = cmd), do: GitCmd.run(cmd, s)
  defp exec(%Cli{}=s, "git-upload-pack " <> _ = cmd), do: GitCmd.run(cmd, s)
  defp exec(%Cli{}=s, cmd), do: start_shell(s, cmd)

  # io_request, handle io requests from the user process,
  # Note, this is not the real I/O-protocol, but the mockup version
  # used between edlin and a user_driver. The protocol tags are
  # similar, but the message set is different.
  # The protocol only exists internally between edlin and a character
  # displaying device...
  # We are *not* really unicode aware yet, we just filter away characters
  # beyond the latin1 range. We however handle the unicode binaries...
  defp io_request({:window_change, oldTty}, buf, tty, _group), do: window_change(tty, oldTty, buf)
  defp io_request({:put_chars, cs}, buf, tty, _group), do: put_chars(bin_to_list(cs), buf, tty)
  defp io_request({:put_chars, :unicode, cs}, buf, tty, _group) do
    put_chars(:unicode.characters_to_list(cs, :unicode), buf, tty)
  end
  defp io_request({:insert_chars, cs}, buf, tty, _group), do: insert_chars(bin_to_list(cs), buf, tty)
  defp io_request({:insert_chars, :unicode, cs}, buf, tty, _group) do
    insert_chars(:unicode.characters_to_list(cs, :unicode), buf, tty)
  end
  defp io_request({:move_rel, n}, buf, tty, _group), do: move_rel(n, buf, tty)
  defp io_request({:delete_chars, n}, buf, tty, _group), do: delete_chars(n, buf, tty)
  defp io_request(:beep, buf, _tty, _group), do: {[7], buf}

  # New in R12
  defp io_request({:get_geometry, :columns}, buf, tty, _group), do: {:ok, tty.width, buf}
  defp io_request({:get_geometry, :rows}, buf, tty, _group), do: {:ok, tty.height, buf}
  defp io_request({:requests, rs}, buf, tty, group), do: io_requests(rs, buf, tty, [], group)
  defp io_request(:tty_geometry, buf, tty, group) do
    io_requests([{:move_rel, 0}, {:put_chars, :unicode, [10]}], buf, tty, [], group)
  end

  # New in 18
  defp io_request({:put_chars_sync, class, cs, reply}, buf, tty, group) do
    # We handle these asynchronous for now, if we need output guarantees
    # we have to handle these synchronously
    send(group, {:reply, reply})
    io_request({:put_chars, class, cs}, buf, tty, group)
  end
  defp io_request(_r, buf, _tty, _group), do: {[], buf}


  defp io_requests([r | rs], buf, tty, acc, group) do
    {chars, newBuf} = io_request(r, buf, tty, group)
    io_requests(rs, newBuf, tty, [acc | chars], group)
  end
  defp io_requests([], buf, _tty, acc, _group), do: {acc, buf}

  # return commands for cursor navigation, assume everything is ansi
  # (vt100), add clauses for other terminal types if needed
  defp ansi_tty(n, l), do: ["\e[", Integer.to_charlist(n), l]

  defp get_tty_command(:up, n, _terminalType), do: ansi_tty(n, ?A)
  defp get_tty_command(:down, n, _terminalType), do: ansi_tty(n, ?B)
  defp get_tty_command(:right, n, _terminalType), do: ansi_tty(n, ?C)
  defp get_tty_command(:left, n, _terminalType), do: ansi_tty(n, ?D)

  @pad 10
  # @tabwidth 8
  @space 32

  # convert input characters to buffer and to writeout
  # Note that the buf is reversed but the buftail is not
  # (this is handy; the head is always next to the cursor)
  defp conv_buf([], accBuf, accBufTail, accWrite, col) do
    {accBuf, accBufTail, Enum.reverse(accWrite), col}
  end
  defp conv_buf([13, 10 | rest], _accBuf, accBufTail, accWrite, _col) do
    conv_buf(rest, [], tl2(accBufTail), [10, 13 | accWrite], 0)
  end
  defp conv_buf([13 | rest], _accBuf, accBufTail, accWrite, _col) do
    conv_buf(rest, [], tl1(accBufTail), [13 | accWrite], 0)
  end
  defp conv_buf([10 | rest], _accBuf, accBufTail, accWrite, _col) do
    conv_buf(rest, [], tl1(accBufTail), [10, 13 | accWrite], 0)
  end
  defp conv_buf([c | rest], accBuf, accBufTail, accWrite, col) do
    conv_buf(rest, [c | accBuf], tl1(accBufTail), [c | accWrite], col + 1)
  end

  # put characters at current position (possibly overwriting
  # characters after current position in buffer)
  defp put_chars(chars, {buf, bufTail, col}, _tty) do
    {newBuf, newBufTail, writeBuf, newCol} = conv_buf(chars, buf, bufTail, [], col)
    {writeBuf, {newBuf, newBufTail, newCol}}
  end

  # insert character at current position
  defp insert_chars([], {buf, bufTail, col}, _tty) do
    {[], {buf, bufTail, col}}
  end
  defp insert_chars(chars, {buf, bufTail, col}, tty) do
    {newBuf, _newBufTail, writeBuf, newCol} =	conv_buf(chars, buf, [], [], col)
    m = move_cursor(newCol + length(bufTail), newCol, tty)
    {[writeBuf, bufTail | m], {newBuf, bufTail, newCol}}
  end

  # delete characters at current position, (backwards if negative argument)
  defp delete_chars(0, {buf, bufTail, col}, _tty), do: {[], {buf, bufTail, col}}
  defp delete_chars(n, {buf, bufTail, col}, tty) when n > 0 do
    newBufTail = nthtail(n, bufTail)
    m = move_cursor(col + length(newBufTail) + n, col, tty)
    {[newBufTail, List.duplicate(@space, n) | m], {buf, newBufTail, col}}
  end
  defp delete_chars(n, {buf, bufTail, col}, tty) do # n < 0
    newBuf = nthtail(-n, buf)
    newCol = case (col + n) do
               v when v >= 0 -> v;
               _ -> 0
             end
    m1 = move_cursor(col, newCol, tty)
    m2 = move_cursor(newCol + length(bufTail) - n, newCol, tty)
    {[m1, bufTail, List.duplicate(@space, -n) | m2], {newBuf, bufTail, newCol}}
  end

  # Window change, redraw the current line (and clear out after it
  # if current window is wider than previous)
  defp window_change(tty, oldTty, {buf, bufTail, col}) do
    if oldTty.width == tty.width do
      {[], buf}
    else
      m1 = move_cursor(col, 0, oldTty)
      n = Enum.max([tty.width - oldTty.width, 0]) * 2
      s = Enum.reverse(buf, [bufTail | List.duplicate(@space, n)])
      m2 = move_cursor(length(buf) + length(bufTail) + n, col, tty)
      {[m1, s | m2], {buf, bufTail, col}}
    end
  end

  # move around in buffer, respecting pad characters
  defp step_over(0, buf, [@pad | bufTail], col), do: {[@pad | buf], bufTail, col + 1}
  defp step_over(0, buf, bufTail, col), do: {buf, bufTail, col}
  defp step_over(n, [c | buf], bufTail, col) when n < 0 do
    n1 = if c == @pad, do: n, else: (n + 1)
    step_over(n1, buf, [c | bufTail], col - 1)
  end
  defp step_over(n, buf, [c | bufTail], col) when n > 0 do
    n1 = if c == @pad, do: n, else: (n - 1)
    step_over(n1, [c | buf], bufTail, col + 1)
  end

  # col and row from position with given width
  defp col(n, w), do: rem(n, w)
  defp row(n, w), do: div(n, w)

  # move relative N characters
  defp move_rel(n, {buf, bufTail, col}, tty) do
    {newBuf, newBufTail, newCol} = step_over(n, buf, bufTail, col)
    m = move_cursor(col, newCol, tty)
    {m, {newBuf, newBufTail, newCol}}
  end

  # give move command for tty
  defp move_cursor(a, a, _tty), do: []
  defp move_cursor(from, to, %Pty{ width: width, term: type }) do
    tcol = case (col(to, width) - col(from, width)) do
	           0 -> ""
	           i when i < 0 -> get_tty_command(:left, -i, type)
	           i -> get_tty_command(:right, i, type)
	         end
    trow = case (row(to, width) - row(from, width)) do
	           0 -> ""
	           j when j < 0 -> get_tty_command(:up, -j, type)
	           j -> get_tty_command(:down, j, type)
	         end
    [tcol | trow]
  end

  # tail, works with empty lists
  defp tl1([_ | a]), do: a
  defp tl1(_), do: []

  # second tail
  defp tl2([_ , _ | a]), do: a
  defp tl2(_), do: []

  # nthtail as in lists, but no badarg if n > the length of list
  defp nthtail(0, a), do: a
  defp nthtail(n, [_ | a]) when n > 0, do: nthtail(n-1, a)
  defp nthtail(_, _), do: []

  defp bin_to_list(b) when is_binary(b), do: String.to_charlist(b)
  defp bin_to_list(l) when is_list(l), do: List.flatten(for a <- l, do: bin_to_list(a))
  defp bin_to_list(i) when is_integer(i), do: i

  # Pty can be undefined if the client never sets any pty options before
  # starting the shell
  defp get_echo(nil), do: true
  defp get_echo(%Pty{ modes: modes }) do
    case Keyword.get(modes, :echo, 1) do
	    0 -> false
	    _ -> true
    end
  end

  # Group is undefined if the pty options are sent between open and
  # shell messages.
  defp set_echo(%Cli{ worker: nil }), do: :ok
  defp set_echo(%Cli{ worker: group, pty: pty }) do
    echo = get_echo(pty)
    send(group, {self(), :echo, echo})
  end

  defp not_zero(0, b), do: b
  defp not_zero(a, _), do: a

  defp empty_buf, do: {"", "", 0}

  defp start_shell(%Cli{ infos: infos }=s) do
    shell = Mg.Shell.start_group(infos[:user], infos[:peer])
    %Cli{ s | worker: shell, buf: empty_buf(), worker_mod: Mg.Shell }
  end

  defp start_shell(%Cli{}=s, cmd) do
    Logger.debug("<ssh> shell exec not implemented (#{cmd})")
    {:failure, s}
  end
end
