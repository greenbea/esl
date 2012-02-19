# esl is a client and a server library for FreeSwitch's ESL protocol
# (c) 2010 Stephane Alnet
# Released under the AGPL3 license
#

#### Overview
# esl is modelled after Node.js' own httpServer and client.
# It offers two low-level ESL handlers, createClient() and
# createServer(), and a higher-level CallServer class.
#
# For more information about ESL consult the FreeSwitch wiki
# [Event Socket](http://wiki.freeswitch.org/wiki/Event_Socket)
#
# Typically a client would be used to trigger calls asynchronously
# (for example in a click-to-dial application); this mode of operation is
# called "inbound" (to FreeSwitch) in the FreeSwitch documentation.
#
# A server will handle calls sent to it using the "socket" diaplan
# application (called "outbound" mode in the FreeSwitch documentation).
# The server is available at a pre-defined port which
# the socket application will specify. See
# [Event Socket Outbound](http://wiki.freeswitch.org/wiki/Event_Socket_Outbound)

#### Usage
#
#     esl = require 'esl'
#
# (The library is a plain Node.js module so you can also call
# it from Javascript. All examples are given using CoffeeScript
# for simplicity.)

net         = require 'net'
querystring = require 'querystring'
util        = require 'util'
assert      = require 'assert'

# If you ever need to debug esl, set
#
#     esl.debug = true
#

exports.debug = false

#### Client Example
# The following code does the equivalent of "fs_cli -x".
#
#     esl = require 'esl'
#
#     # Open connection, send arbitrary API command, disconnect.
#     fs_command = (cmd,cb) ->
#       client = esl.createClient()
#       client.on 'esl_auth_request', (req,res) ->
#         res.auth 'ClueCon', (req,res) ->
#           res.api cmd, (req,res) ->
#             res.exit ->
#               client.end()
#       if cb?
#         client.on 'close', cb
#       client.connect(8021, '127.0.0.1')
#
#     # Example
#     fs_command "reloadxml"
#
#  Note: Use
#
#     res.event_json 'HEARTBEAT'
#
#  to start receiving event notifications.

#### CallServer Example
#
# From the dialplan, use
#    <action application="socket" data="127.0.0.1:7000 async full"/>
# to hand the call over to an ESL server.
#
# If you'd like to get realtime channel variables and synchronous commands, do
#
#     server = esl.createCallServer true
#
#     server.on 'CONNECT', (req,res) ->
#       res.execute 'verbose_events', null, (req,res) ->
#         # You may now access realtime variables as
#         foo = req.body.variable_foo
#         res.execute 'play-file', 'voicemail/vm-hello', (req,res) ->
#           # This call with wait for the command to finish
#           # Your application continues here
#
#     server.listen 7000
#
# Note that although the socket command was called (in the dialplan above) with
# the "async" parameter, createCallServer is processing the commands synchronously.
# Of course you can work synchronously without using verbose_events; you may still
# obtain realtime values by using the API (lookup the "eval" command).
# However you cannot use verbose_events asynchronously, unless you capture the
# CHANNEL_EXECUTE_COMPLETE event.
#
# An asynchronous server will look this way:
#
#     server = esl.createCallServer()
#
#     server.on 'CONNECT', (req,res) ->
#       # Start processing the call
#       # Channel data is available as req.channel_data
#       # Channel UUID is available as req.unique_id
#       # For example:
#       uri = req.channel_data.variable_sip_req_uri
#
#     # Other FreeSwitch channel events are available as well:
#     server.on 'CHANNEL_ANSWER', (req,res) ->
#       util.log 'Call was answered'
#       # You can force a disconnect (call hangup) using:
#       server.force_disconnect()
#     server.on 'CHANNEL_HANGUP_COMPLETE', (req,res) ->
#       util.log 'Call was disconnected'
#
#     # Start the ESL server on port 7000.
#     server.listen 7000
#

#### Headers parser
# ESL framing contains headers and a body.
# The header must be decoded first to learn
# the presence and length of the body.

parse_header_text = (header_text) ->
  if exports.debug
    util.log "parse_header_text(#{header_text})"

  header_lines = header_text.split("\n")
  headers = {}
  for line in header_lines
    do (line) ->
      [name,value] = line.split /: /, 2
      headers[name] = value

  # Decode headers: in the case of the "connect" command,
  # the headers are all URI-encoded.
  if headers['Reply-Text']?[0] is '%'
    for name of headers
      headers[name] = querystring.unescape(headers[name])

  return headers

#### ESL stream parser
# The ESL parser will parse an incoming ESL stream, whether
# your code is acting as a client (connected to the FreeSwitch
# ESL server) or as a server (called back by FreeSwitch due to the
# "socket" application command).
class eslParser
  constructor: (@socket) ->
    @body_length = 0
    @buffer = ""

  # When capturing the body, buffer contains the current data
  # (text), and body_length contains how many bytes are expected to
  # be read in the body.
  capture_body: (data) ->
    @buffer += data

    # As long as the whole body hasn't been received, keep
    # adding the new data into the buffer.
    if @buffer.length < @body_length
      return

    # Consume the body once it has been fully received.
    body = @buffer.substring(0,@body_length)
    @buffer = @buffer.substring(@body_length)
    @body_length = 0

    # Process the content
    @process @headers, body
    @headers = {}

    # Re-parse whatever data was left after the body was
    # fully consumed.
    @capture_headers ''

  # Capture headers, meaning up to the first blank line.
  capture_headers: (data) ->
    @buffer += data

    # Wait until we reach the end of the header.
    header_end = @buffer.indexOf("\n\n")
    if header_end < 0
      return

    # Consume the headers
    header_text = @buffer.substring(0,header_end)
    @buffer = @buffer.substring(header_end+2)

    # Parse the header lines
    @headers = parse_header_text(header_text)

    # Figure out whether a body is expected
    if @headers["Content-Length"]
      @body_length = @headers["Content-Length"]
      # Parse the body (and eventually process)
      @capture_body ''

    else
      # Process the (header-only) content
      @process @headers
      @headers = {}

      # Re-parse whatever data was left after these headers
      # were fully consumed.
      @capture_headers ''

  # Dispatch incoming data into the header or body parsers.
  on_data: (data) ->
    if exports.debug
      util.log "on_data(#{data})"

    # Capture the body as needed
    if @body_length > 0
      return @capture_body data
    else
      return @capture_headers data

  # For completeness provide an on_end() method.
  # TODO: it probably should make sure the buffer is empty?
  on_end: () ->
    if exports.debug
      util.log "Parser: end of stream"
      if @buffer.length > 0
        util.log "Buffer is not empty, left over: #{@buffer}"

#### ESL request
class eslRequest
  constructor: (@headers,@body) ->

#### ESL response and associated API
class eslResponse
  constructor: (@socket) ->

  # If a callback is provided we attempt to trigger it
  # when the operation completes.
  # By default, the trigger is done as soon as the ESL command
  # finishes.
  intercept_response: (command,args,cb) ->
    # Make sure we are the only one receiving command replies
    @socket.removeAllListeners('esl_command_reply')
    @socket.removeAllListeners('esl_api_response')
    # Register the callback for the proper event types.
    @socket.on 'esl_command_reply', cb
    @socket.on 'esl_api_response', cb

  # A generic way of sending commands back to FreeSwitch.
  #
  #      send (string,hash,function(req,res))
  #
  # is normally not used directly.

  send: (command,args,cb) ->
      if exports.debug
        util.log util.inspect command: command, args: args

      if cb?
        @intercept_response command, args, cb

      # Send the command out.
      @socket.write "#{command}\n"
      if args?
        for key, value of args
          @socket.write "#{key}: #{value}\n"
      @socket.write "\n"

  on: (event,listener) -> @socket.on(event,listener)

  end: () -> @socket.end()

  #### Channel-level commands

  # Send an API command, see [Mod commands](http://wiki.freeswitch.org/wiki/Mod_commands)
  api: (command,cb) ->
    @send "api #{command}", null, cb

  # Send an API command in the background.
  # The callback will receive the Job UUID (instead of the usual request/response pair).
  bgapi: (command,cb) ->
    @send "bgapi #{command}", null, (req,res) ->
      if cb?
        r = res.header['Reply-Text']?.match /\+OK Job-UUID: (.+)$/
        cb r[1]

  #### Event reception and filtering

  # Request that the server send us events in JSON format.
  # (For all useful purposes this is the only supported format
  # in this module.)
  # For example:
  #
  #     res.event_json 'HEARTBEAT'
  #
  event_json: (events...,cb) ->
    @send "event json #{events.join(' ')}", null, cb

  # Remove the given event types from the events ACL.
  nixevent: (events...,cb) ->
    @send "nixevent #{events.join(' ')}", null, cb

  # Remove all events types.
  noevents: (cb) ->
    @send "noevents", null, cb

  # Generic event filtering
  filter: (header,value,cb) ->
    @send "filter #{header} #{value}", null, cb

  filter_delete: (header,value,cb) ->
    if value?
      @send "filter #{header} #{value}", null, cb
    else
      @send "filter #{header}", null, cb

  # Send an event into the FreeSwitch event queue.
  sendevent: (event_name,args,cb) ->
    @send "sendevent #{event_name}", args, cb

  # Authenticate, typically used in a client:
  #
  #     client = esl.createClient()
  #     client.on 'esl_auth_request', (req,res) ->
  #       res.auth 'ClueCon', (req,res) ->
  #         # Start sending other commands here.
  #     client.connect ...
  #
  auth: (password,cb)       -> @send "auth #{password}", null, cb

  # connect() and linger() are used in server mode.
  connect: (cb)             -> @send "connect", null, cb    # Outbound mode

  linger: (cb)              -> @send "linger", null, cb     # Outbound mode

  # Send the exit command to the FreeSwitch socket.
  exit: (cb)                -> @send "exit", null, cb

  #### Event logging commands
  log: (level,cb) ->
    [level,cb] = [null,level] if typeof(level) is 'function'
    if level?
      @send "log #{level}", null, cb
    else
      @send "log", null, cb

  nolog: (cb)                 -> @send "nolog", null, cb

  #### Message sending
  # Send Message (to a UUID)

  sendmsg_uuid: (uuid,command,args,cb) ->
    options = args ? {}
    options['call-command'] = command
    execute_text = if uuid? then "sendmsg #{uuid}" else 'sendmsg'
    @send execute_text, options, cb

  # Same, assuming server/outbound ESL mode:

  sendmsg: (command,args,cb) -> @sendmsg_uuid null, command, args, cb

  #### Client-mode ("inbound") commands
  # The target UUID must be specified.

  # Execute an application for the given UUID (in client mode)

  execute_uuid: (uuid,app_name,app_arg,cb) ->
    options =
      'execute-app-name': app_name
      'execute-app-arg':  app_arg
    @sendmsg_uuid uuid, 'execute', options, cb

  # Hangup a call

  hangup_uuid: (uuid,hangup_cause,cb) ->
    hangup_cause ?= 'NORMAL_UNSPECIFIED'
    options =
      'hangup-cause': hangup_cause
    @sendmsg_uuid uuid, 'hangup', options, cb

  unicast_uuid: (uuid,args,cb) ->
    @sendmsg_uuid uuid, 'unicast', args, cb

  # nomedia_uuid: TODO

  #### Server-mode commands
  # The target UUID is our (own) call UUID.

  # Execute an application for the current UUID (in server/outbound mode)

  execute: (app_name,app_arg,cb)  -> @execute_uuid null, app_name, app_arg, cb

  hangup: (hangup_cause,cb)       -> @hangup_uuid  null, hangup_cause, cb

  unicast: (args,cb)              -> @unicast_uuid null, args, cb

  # nomedia: TODO

#### Connection Listener (socket events handler)
# This is modelled after Node.js' http.js

connectionListener= (socket,intercept_response) ->

  new_response = ->
    res = new eslResponse socket
    if intercept_response?
      res.intercept_response = intercept_response
    return res

  socket.setEncoding('ascii')
  parser = new eslParser socket
  socket.on 'data', (data) ->  parser.on_data(data)
  socket.on 'end',  ()     ->  parser.on_end()
  parser.process = (headers,body) ->
    if exports.debug
      util.log util.inspect headers: headers, body: body

    # Rewrite headers as needed to work around some weirdnesses in
    # the protocol;
    # and assign unified event IDs to the ESL Content-Types.

    switch headers['Content-Type']
      when 'auth/request'
        event = 'esl_auth_request'
      when 'command/reply'
        event = 'esl_command_reply'
        # Apparently a bug in the response to "connect"
        if headers['Event-Name'] is 'CHANNEL_DATA'
          body = headers
          headers = {}
          for n in ['Content-Type','Reply-Text','Socket-Mode','Control']
            headers[n] = body[n]
            delete body[n]
      when 'text/event-json'
        try
          body = JSON.parse(body)
        catch error
          util.log "JSON #{error} in #{body}"
          return
        event = 'esl_event'
      when 'text/event-plain'
        body = parse_header_text(body)
        event = 'esl_event'
      when 'log/data'
        event = 'esl_log_data'
      when 'text/disconnect-notice'
        event = 'esl_disconnect_notice'
      when 'api/response'
        event = 'esl_api_response'
      else
        event = headers['Content-Type']
    # Build request and response and send them out.
    req = new eslRequest headers,body
    res = new_response()
    if intercept_response?
      res.intercept_response = intercept_response
    if exports.debug
      util.log util.inspect event:event, req:req, res:res
    socket.emit event, req, res
  # Get things started
  socket.emit 'esl_connect', new_response()

#### ESL Server

class eslServer extends net.Server
  constructor: (requestListener,intercept_response) ->
    @on 'connection', (socket) ->
      socket.on 'esl_connect', requestListener
      connectionListener socket, intercept_response
    super()

# You can use createServer(callback) from your code.
exports.createServer = (requestListener) -> return new eslServer(requestListener)

#### ESL client
class eslClient extends net.Socket
  constructor: (intercept_response) ->
    @on 'connect', ->
      connectionListener @, intercept_response
    super()

exports.createClient = -> return new eslClient()

#### CallServer: a higher-level interface
#
# This interface is based on my
# [prepaid code](http://stephane.shimaore.net/git/?p=ccnq3.git;a=blob;f=applications/prepaid/)
# and handles the nitty-gritty of setting up the server properly.

synchronous_intercept_response = (command,args,cb) ->
  if command is 'sendmsg' and args['call-command'] is 'execute'
    @socket.on 'CHANNEL_EXECUTE_COMPLETE', cb
  else
    # Make sure we are the only one receiving command replies
    @socket.removeAllListeners('esl_command_reply')
    @socket.removeAllListeners('esl_api_response')
    # Register the callback for the proper event types.
    @socket.on 'esl_command_reply', cb
    @socket.on 'esl_api_response', cb

exports.createCallServer = (synchronous) ->

    intercept_response = null
    if synchronous
      intercept_response = synchronous_intercept_response

    Unique_ID = 'Unique-ID'

    listener = (res) ->
      if exports.debug
        util.log "Incoming connection"
        util.log util.inspect res

      res.connect (req,res) =>

        # Channel data
        channel_data = req.body
        # UUID
        unique_id = channel_data[Unique_ID]

        if exports.debug
          util.log "Incoming call UUID = #{unique_id}"

        # Clean-up at the end of the connection.
        res.on 'esl_disconnect_notice', (req,res) ->
          if exports.debug
            util.log "Received ESL disconnection notice"
          switch req.headers['Content-Disposition']
            when 'linger'      then res.exit()
            when 'disconnect'  then res.end()

        # Use this from your code to force a disconnection.
        #
        #     res.emit 'force_disconnect'
        #
        res.on 'force_disconnect', ->
          util.log 'Hangup call'
          @bgapi "uuid_kill #{unique_id}"

        # Translate channel events into server events.
        res.on 'esl_event', (req,res) ->
          req.channel_data = channel_data
          req.unique_id = unique_id
          server.emit req.body['Event-Name'], req, res

        # Handle the incoming connection
        res.linger (req,res) ->
          res.filter Unique_ID, unique_id, (req,res) ->
            res.event_json 'ALL', (req,res) ->
              req.channel_data = channel_data
              req.unique_id = unique_id
              server.emit 'CONNECT', req, res

    server = new eslServer listener, intercept_response
