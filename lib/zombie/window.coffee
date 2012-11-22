# 
createDocument  = require("./document")
EventSource     = require("eventsource")
History         = require("./history")
JSDOM           = require("jsdom")
WebSocket       = require("ws")
URL             = require("url")
XMLHttpRequest  = require("./xhr")


Events      = JSDOM.dom.level3.events
HTML        = JSDOM.dom.level3.html


# The current window in context.  Set during _evaluate, used by postMessage.
inContext = null


# Create and return a new Window.
#
# Parameters
# browser   - Browser that owns this window
# param     - Data to submit (used by forms)
# encoding  - Encoding MIME type (used by forms)
# history   - This window shares history with other windows
# method    - HTTP method (used by forms)
# name      - Window name (optional)
# opener    - Opening window (window.open call)
# parent    - Parent window (for frames)
# url       - Set document location to this URL upon opening
createWindow = ({ browser, params, encoding, history, method, name, opener, parent, url })->
  name ||= ""
  url ||= "about:blank"

  window = JSDOM.createWindow(HTML)
  global = window.getGlobal()
  # window`s have a closed property defaulting to false
  closed = false

  # Access to browser
  Object.defineProperty window, "browser",
    value: browser
    enumerable: true

  # -- Document --

  # Each window has its own document
  document = createDocument(browser, window, history.url || browser.referer)
  Object.defineProperty window, "document",
    value: document
    enumerable: true


  # -- DOM Window features

  Object.defineProperty window, "name",
    value: name
    enumerable: true
  # If this is an iframe within a parent window
  if parent
    Object.defineProperty window, "parent",
      value: parent
      enumerable: true
    Object.defineProperty window, "top",
      value: parent.top
      enumerable: true
  else
    Object.defineProperty window, "parent",
      value: global
      enumerable: true
    Object.defineProperty window, "top",
      value: global
      enumerable: true

  # If this was opened from another window
  Object.defineProperty window, "opener",
    value: opener && opener
    enumerable: true

  # Window title is same as document title
  Object.defineProperty window, "title",
    get: ->
      return document.title
    set: (title)->
      document.title = title
    enumerable: true

  Object.defineProperty window, "console",
    value: browser.console
    enumerable: true

  # javaEnabled, present in browsers, not in spec Used by Google Analytics see
  # https://developer.mozilla.org/en/DOM/window.navigator.javaEnabled
  Object.defineProperties window.navigator,
    cookieEnabled: { value: true }
    javaEnabled:   { value: -> false }
    plugins:       { value: [] }
    userAgent:     { value: browser.userAgent }
    vendor:        { value: "Zombie Industries" }

  # Add cookies, storage, alerts/confirm, XHR, WebSockets, JSON, Screen, etc
  browser._cookies.extend(window)
  browser._storages.extend(window)
  browser._interact.extend(window)

  Object.defineProperties window,
    File:           { value: File }
    Event:          { value: Events.Event }
    screen:         { value: new Screen() }
    MouseEvent:     { value: Events.MouseEvent }
    MutationEvent:  { value: Events.MutationEvent }
    UIEvent:        { value: Events.UIEvent }

  # Base-64 encoding/decoding
  window.atob = (string)->
    new Buffer(string, "base64").toString("utf8")
  window.btoa = (string)->
    new Buffer(string, "utf8").toString("base64")

  # Constructor for XHLHttpRequest
  window.XMLHttpRequest = ->
    return new XMLHttpRequest(window)

  # Constructor for EventSource, URL is relative to document's.
  window.EventSource = (url)->
    url = HTML.resourceLoader.resolve(document, url)
    window.setInterval((->), 100) # We need this to trigger event loop
    return new EventSource(url)

  # Web sockets
  window.WebSocket = (url, protocol)->
    url = HTML.resourceLoader.resolve(document, url)
    origin = "#{window.location.protocol}//#{window.location.host}"
    return new WebSocket(url, origin: origin, protocol: protocol)

  window.Image = (width, height)->
    img = new HTML.HTMLImageElement(window.document)
    img.width = width
    img.height = height
    return img

  window.resizeTo = (width, height)->
    window.outerWidth = window.innerWidth = width
    window.outerHeight = window.innerHeight = height
  window.resizeBy = (width, height)->
    window.resizeTo(window.outerWidth + width,  window.outerHeight + height)

  # Help iframes talking with each other
  window.postMessage = (data, targetOrigin)->
    document = window.document
    # Create the event now, but dispatch asynchronously
    event = document.createEvent("MessageEvent")
    event.initEvent("message", false, false)
    event.data = data
    # Window A (source) calls B.postMessage, to determine A we need the
    # caller's window.

    # DDOPSON-2012-11-09 - inContext.getGlobal() is used here so that for
    # website code executing inside the sandbox context, event.source == window.
    # Even though the inContext object is mapped to the sandboxed version of the
    # object returned by getGlobal, they are not the same object ie,
    # inContext.foo == inContext.getGlobal().foo, but inContext !=
    # inContext.getGlobal()
    event.source = inContext.getGlobal()
    origin = event.source.location
    event.origin = URL.format(protocol: origin.protocol, host: origin.host)
    window.dispatchEvent(event)


  # -- JavaScript evaluation

  # Evaulate in context of window. This can be called with a script (String) or a function.
  window._evaluate = (code, filename)->
    try
      # The current window, postMessage and window.close need this
      [original, inContext] = [inContext, window]
      inContext = window
      if typeof(code) == "string" || code instanceof String
        result = global.run(code, filename)
      else if code
        result = code.call(global)
      browser.emit("evaluated", code, result)
      return result
    catch error
      error.filename ||= filename
      browser.emit("error", error)
    finally
      inContext = original

  # Default onerror handler.
  window.onerror = (event)->
    error = event.error || new Error("Error loading script")
    browser.emit("error", error)


  # -- Event loop --

  eventQueue = browser.eventLoop.createEventQueue(window)
  Object.defineProperties window,
    _eventQueue:
      value: eventQueue
    setTimeout:
      value: eventQueue.setTimeout.bind(eventQueue)
    clearTimeout:
      value: eventQueue.clearTimeout.bind(eventQueue)
    setInterval:
      value: eventQueue.setInterval.bind(eventQueue)
    clearInterval:
      value: eventQueue.clearInterval.bind(eventQueue)


  # -- Opening and closing --

  # Open one window from another.
  window.open = (url, name, features)->
    url = url && HTML.resourceLoader.resolve(document, url)
    return browser.open(name: name, url: url, opener: window)

  # Indicates if window was closed
  Object.defineProperty window, "closed",
    get: -> closed
    enumerable: true

  # Destroy all the history (and all its windows), frames, and Contextify
  # global.
  window._destroy = ->
    # We call history.distroy which calls destroy on all windows, so need to
    # avoid infinite loop.
    return if closed
    closed = true
    for frame in window.frames
      frame.close()
    eventQueue.destroy()
    window.document = null
    window.dispose()
    return

  # window.close actually closes the tab, and disposes of all windows in the history.
  # Also used to close iframe.
  window.close = ->
    return if parent || closed
    # Only opener window can close window; any code that's not running from
    # within a window's context can also close window.
    if inContext == opener || inContext == null
      browser.emit("closed", window)
      history.destroy()
      window._destroy() # do this last to prevent infinite loop
    else
      browser.log("Scripts may not close windows that were not opened by script")
    return

  # -- Navigating --

  history.updateLocation(window, url)

  # Each window maintains its own view of history
  windowHistory =
    forward:      history.go.bind(history, 1)
    back:         history.go.bind(history, -1)
    go:           history.go.bind(history)
    pushState:    history.pushState.bind(history)
    replaceState: history.replaceState.bind(history)
  Object.defineProperties windowHistory,
    length:
      get: -> return history.length
      enumerable: true
    state:
      get: -> return history.state
      enumerable: true
  Object.defineProperties window,
    history:
      value: windowHistory

  # Window is now open, next load the document.
  browser.emit("opened", window)

  # Form submission uses this
  window._submit = (params)->
    browser.emit("submit", params.form, params.url)
    history.submit(params)
  # Load the document associated with this window.
  loadDocument document: document, history: history, url: url, method: method, encoding: encoding, params: params
  return window


# Load document. Also used to submit form.
loadDocument = ({ document, history, url, method, encoding, params })->
  window = document.window
  browser = window.browser

  # Called on wrap up to update browser with outcome.
  done = (error, url)->
    if error
      browser.emit("error", error)
    else
      if url
        history.updateLocation(window, url)
      browser.emit("loaded", document)

  method = (method || "GET").toUpperCase()
  if method == "POST"
    headers =
      "content-type": encoding || "application/x-www-form-urlencoded"

  # Let's handle the specifics of each protocol
  { protocol, pathname } = URL.parse(url)
  switch protocol
    when "about:"
      done()

    when "javascript:"
      try
        window._evaluate(pathname, "javascript:")
        done()
      catch error
        done(error)

    when "http:", "https:", "file:"
      # Proceeed to load resource ...
      headers = headers || {}
      unless headers.referer
        # HTTP header Referer, but Document property referrer
        headers.referer = document.referrer

      window._eventQueue.http method, url, headers: headers, params: params, target: document, (error, response)->
        if error
          document.open()
          document.write(error.message || error)
          document.close()
          done(error)
          return

        # JSDOM fires load event on document but not on window
        windowLoaded = (event)->
          document.removeEventListener("load", windowLoaded)
          window.dispatchEvent(event)
        document.addEventListener("load", windowLoaded)

        # JSDOM fires load event on document but not on window
        contentLoaded = (event)->
          document.removeEventListener("DOMContentLoaded", contentLoaded)
          window.dispatchEvent(event)
        document.addEventListener("DOMContentLoaded", contentLoaded)

        # Give event handler chance to register listeners.
        window.browser.emit("loading", document)

        if response.body
          body = response.body.toString("utf8")
        else
          body = "<body></body>"

        document.open()
        document.write(body)
        document.close()

        # Error on any response that's not 2xx, or if we're not smart enough to
        # process the content and generate an HTML DOM tree from it.
        if response.statusCode >= 400
          done(new Error("Server returned status code #{response.statusCode} from #{url}"))
        else if document.documentElement
          done(null, response.url)
        else
          done(new Error("Could not parse document at #{url}"))

    else # but not any other protocol for now
      done(new Error("Cannot load resource #{url}, unsupported protocol"))


# Wrap dispatchEvent to support inContext and error handling.
jsdomDispatchElement = HTML.Element.prototype.dispatchEvent
HTML.Node.prototype.dispatchEvent = (event)->
  self = this
  # Could be node, window or document
  document = self.ownerDocument || self.document || self
  window = document.window
  window.browser.emit("event", event, self)

  if self.getAttribute
    if onhandler = self.getAttribute("on#{event.type}")
      console.log event.type, onhandler

  return window._evaluate ->
    return jsdomDispatchElement.call(self, event)


# Screen object provides access to screen dimensions
class Screen
  constructor: ->
    @top = @left = 0
    @width = 1280
    @height = 800

  @prototype.__defineGetter__ "availLeft", -> 0
  @prototype.__defineGetter__ "availTop", -> 0
  @prototype.__defineGetter__ "availWidth", -> 1280
  @prototype.__defineGetter__ "availHeight", -> 800
  @prototype.__defineGetter__ "colorDepth", -> 24
  @prototype.__defineGetter__ "pixelDepth", -> 24


# File access, not implemented yet
class File


module.exports = createWindow
