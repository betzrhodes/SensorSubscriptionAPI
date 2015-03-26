/******************** Rocky Classes ********************/
class Rocky {
    _handlers = null;

    // Settings:
    _timeout = 10;
    _strictRouting = false;
    _allowUnsecure = false;
    _accessControl = true;

    constructor(settings = {}) {
        if ("timeout" in settings) _timeout = settings.timeout;
        if ("allowUnsecure" in settings) _allowUnsecure = settings.allowUnsecure;
        if ("strictRouting" in settings) _strictRouting = settings.strictRouting;
        if ("accessControl" in settings) _accessConrol = settings.accessControl;

        _handlers = {
            authorize = _defaultAuthorizeHandler.bindenv(this),
            onUnauthorized = _defaultUnauthorizedHandler.bindenv(this),
            onTimeout = _defaultTimeoutHandler.bindenv(this),
            onNotFound = _defaultNotFoundHandler.bindenv(this),
            onException = _defaultExceptionHandler.bindenv(this),
        };

        http.onrequest(_onrequest.bindenv(this));
    }

    /************************** [ PUBLIC FUNCTIONS ] **************************/
    function on(verb, signature, callback) {
        // Register this signature and verb against the callback
        verb = verb.toupper();
        signature = signature.tolower();
        if (!(signature in _handlers)) _handlers[signature] <- {};

        local routeHandler = Rocky.Route(callback);
        _handlers[signature][verb] <- routeHandler;

        return routeHandler;
    }

    function post(signature, callback) {
        return on("POST", signature, callback);
    }

    function get(signature, callback) {
        return on("GET", signature, callback);
    }

    function put(signature, callback) {
        return on("PUT", signature, callback);
    }

    function authorize(callback) {
        _handlers.authorize <- callback;
        return this;
    }

    function onUnauthorized(callback) {
        _handlers.onUnauthorized <- callback;
        return this;
    }

    function onTimeout(callback, timeout = 10) {
        _handlers.onTimeout <- callback;
        _timeout = timeout;
        return this;
    }

    function onNotFound(callback) {
        _handlers.onNotFound <- callback;
        return this;
    }

    function onException(callback) {
        _handlers.onException <- callback;
        return this;
    }

    // Adds access control headers
    function _addAccessControl(res) {
        res.header("Access-Control-Allow-Origin", "*")
        res.header("Access-Control-Allow-Headers", "Origin, X-Requested-With, Content-Type, Accept");
        res.header("Access-Control-Allow-Methods", "POST, PUT, GET, OPTIONS");
    }

    /************************** [ PRIVATE FUNCTIONS ] *************************/
    function _onrequest(req, res) {

        // Add access control headers if required
        if (_accessControl) _addAccessControl(res);

        // Setup the context for the callbacks
        local context = Rocky.Context(req, res);

        // Check for unsecure reqeusts
        if (_allowUnsecure == false && "x-forwarded-proto" in req.headers && req.headers["x-forwarded-proto"] != "https") {
            context.send(405, "HTTP not allowed.");
            return;
        }

        // Parse the request body back into the body
        try {
            req.body = _parse_body(req);
        } catch (e) {
            server.log("Parse error '" + e + "' when parsing:\r\n" + req.body)
            context.send(400, e);
            return;
        }

        // Look for a handler for this path
        local route = _handler_match(req);
        if (route) {
            // if we have a handler
            context.path = route.path;
            context.matches = route.matches;

            // parse auth
            context.auth = _parse_authorization(context);

            // Create timeout
            local onTimeout = _handlers.onTimeout;
            local timeout = _timeout;

            if (route.handler.hasTimeout()) {
                onTimeout = route.handler.onTimeout;
                timeout = route.handler.timeout;
            }

            context.setTimeout(_timeout, onTimeout);
            route.handler.execute(context, _handlers);
        } else {
            // if we don't have a handler
            _handlers.onNotFound(context);
        }
    }

    function _parse_body(req) {
        if ("content-type" in req.headers && req.headers["content-type"] == "application/json") {
            if (req.body == "" || req.body == null) return null;
            return http.jsondecode(req.body);
        }
        if ("content-type" in req.headers && req.headers["content-type"] == "application/x-www-form-urlencoded") {
            return http.urldecode(req.body);
        }
        if ("content-type" in req.headers && req.headers["content-type"].slice(0,20) == "multipart/form-data;") {
            local parts = [];
            local boundary = req.headers["content-type"].slice(30);
            local bindex = -1;
            do {
                bindex = req.body.find("--" + boundary + "\r\n", bindex+1);
                if (bindex != null) {
                    // Locate all the parts
                    local hstart = bindex + boundary.len() + 4;
                    local nstart = req.body.find("name=\"", hstart) + 6;
                    local nfinish = req.body.find("\"", nstart);
                    local fnstart = req.body.find("filename=\"", hstart) + 10;
                    local fnfinish = req.body.find("\"", fnstart);
                    local bstart = req.body.find("\r\n\r\n", hstart) + 4;
                    local fstart = req.body.find("\r\n--" + boundary, bstart);

                    // Pull out the parts as strings
                    local headers = req.body.slice(hstart, bstart);
                    local name = null;
                    local filename = null;
                    local type = null;
                    foreach (header in split(headers, ";\n")) {
                        local kv = split(header, ":=");
                        if (kv.len() == 2) {
                            switch (strip(kv[0]).tolower()) {
                                case "name":
                                    name = strip(kv[1]).slice(1, -1);
                                    break;
                                case "filename":
                                    filename = strip(kv[1]).slice(1, -1);
                                    break;
                                case "content-type":
                                    type = strip(kv[1]);
                                    break;
                            }
                        }
                    }
                    local data = req.body.slice(bstart, fstart);
                    local part = { "name": name, "filename": filename, "data": data, "content-type": type };

                    parts.push(part);
                }
            } while (bindex != null);

            return parts;
        }

        // Nothing matched, send back the original body
        return req.body;
    }

    function _parse_authorization(context) {
        if ("authorization" in context.req.headers) {
            local auth = split(context.req.headers.authorization, " ");

            if (auth.len() == 2 && auth[0] == "Basic") {
                // Note the username and password can't have colons in them
                local creds = http.base64decode(auth[1]).tostring();
                creds = split(creds, ":");
                if (creds.len() == 2) {
                    return { authType = "Basic", user = creds[0], pass = creds[1] };
                }
            } else if (auth.len() == 2 && auth[0] == "Bearer") {
                // The bearer is just the password
                if (auth[1].len() > 0) {
                    return { authType = "Bearer", user = auth[1], pass = auth[1] };
                }
            }
        }

        return { authType = "None", user = "", pass = "" };
    }

    function _extract_parts(routeHandler, path, regexp = null) {
        local parts = { path = [], matches = [], handler = routeHandler };

        // Split the path into parts
        foreach (part in split(path, "/")) {
            parts.path.push(part);
        }

        // Capture regular expression matches
        if (regexp != null) {
            local caps = regexp.capture(path);
            local matches = [];
            foreach (cap in caps) {
                parts.matches.push(path.slice(cap.begin, cap.end));
            }
        }

        return parts;
    }

    function _handler_match(req) {
        local signature = req.path.tolower();
        local verb = req.method.toupper();

        // ignore trailing /s if _strictRouting == false
        if(!_strictRouting) {
            while (signature.len() > 1 && signature[signature.len()-1] == '/') {
                signature = signature.slice(0, signature.len()-1);
            }
        }

        if ((signature in _handlers) && (verb in _handlers[signature])) {
            // We have an exact signature match
            return _extract_parts(_handlers[signature][verb], signature);
        } else if ((signature in _handlers) && ("*" in _handlers[signature])) {
            // We have a partial signature match
            return _extract_parts(_handlers[signature]["*"], signature);
        } else {
            // Let's iterate through all handlers and search for a regular expression match
            foreach (_signature,_handler in _handlers) {
                if (typeof _handler == "table") {
                    foreach (_verb,_callback in _handler) {
                        if (_verb == verb || _verb == "*") {
                            try {
                                local ex = regexp(_signature);
                                if (ex.match(signature)) {
                                    // We have a regexp handler match
                                    return _extract_parts(_callback, signature, ex);
                                }
                            } catch (e) {
                                // Don't care about invalid regexp.
                            }
                        }
                    }
                }
            }
        }
        return null;
    }

    /*************************** [ DEFAULT HANDLERS ] *************************/
    function _defaultAuthorizeHandler(context) {
        return true;
    }

    function _defaultUnauthorizedHandler(context) {
        context.send(401, "Unauthorized");
    }

    function _defaultNotFoundHandler(context) {
        context.send(404, format("No handler for %s %s", context.req.method, context.req.path));
    }

    function _defaultTimeoutHandler(context) {
        context.send(500, format("Agent Request Timedout after %i seconds.", _timeout));
    }

    function _defaultExceptionHandler(context, ex) {
        context.send(500, "Agent Error: " + ex);
    }
}
class Rocky.Route {
    handlers = null;
    timeout = null;

    _callback = null;

    constructor(callback) {
        handlers = {};
        timeout = 10;

        _callback = callback;
    }

    /************************** [ PUBLIC FUNCTIONS ] **************************/
    function execute(context, defaultHandlers) {
        try {
            // setup handlers
            foreach (handlerName, handler in defaultHandlers) {
                if (!(handlerName in handlers)) handlers[handlerName] <- handler;
            }

            if(handlers.authorize(context)) {
                _callback(context);
            }
            else {
                handlers.onUnauthorized(context);
            }
        } catch(ex) {
            handlers.onException(context, ex);
        }
    }

    function authorize(callback) {
        handlers.authorize <- callback;
        return this;
    }

    function onException(callback) {
        handlers.onException <- callback;
        return this;
    }

    function onUnauthorized(callback) {
        handlers.onUnauthorized <- callback;
        return this;
    }

    function onTimeout(callback, t = 10) {
        handlers.onTimeout <- callback;
        timeout = t;
        return this;
    }

    function hasTimeout() {
        return ("onTimeout" in handlers);
    }
}
class Rocky.Context {
    req = null;
    res = null;
    sent = false;
    id = null;
    time = null;
    auth = null;
    path = null;
    matches = null;
    timer = null;
    static _contexts = {};

    constructor(_req, _res) {
        req = _req;
        res = _res;
        sent = false;
        time = date();

        // Identify and store the context
        do {
            id = math.rand();
        } while (id in _contexts);
        _contexts[id] <- this;
    }

    /************************** [ PUBLIC FUNCTIONS ] **************************/
    function get(id) {
        if (id in _contexts) {
            return _contexts[id];
        } else {
            return null;
        }
    }

    function isbrowser() {
        return (("accept" in req.headers) && (req.headers.accept.find("text/html") != null));
    }

    function getHeader(key, def = null) {
        key = key.tolower();
        if (key in req.headers) return req.headers[key];
        else return def;
    }

    function setHeader(key, value) {
        return res.header(key, value);
    }

    function send(code, message = null) {
        // Cancel the timeout
        if (timer) {
            imp.cancelwakeup(timer);
            timer = null;
        }

        // Remove the context from the store
        if (id in _contexts) {
            delete Rocky.Context._contexts[id];
        }

        // Has this context been closed already?
        if (sent) {
            return false;
        }

        if (message == null && typeof code == "integer") {
            // Empty result code
            res.send(code, "");
        } else if (message == null && typeof code == "string") {
            // No result code, assume 200
            res.send(200, code);
        } else if (message == null && (typeof code == "table" || typeof code == "array")) {
            // No result code, assume 200 ... and encode a json object
            res.header("Content-Type", "application/json; charset=utf-8");
            res.send(200, http.jsonencode(code));
        } else if (typeof code == "integer" && (typeof message == "table" || typeof message == "array")) {
            // Encode a json object
            res.header("Content-Type", "application/json; charset=utf-8");
            res.send(code, http.jsonencode(message));
        } else {
            // Normal result
            res.send(code, message);
        }
        sent = true;
    }

    function setTimeout(timeout, callback) {
        // Set the timeout timer
        if (timer) imp.cancelwakeup(timer);
        timer = imp.wakeup(timeout, function() {
            if (callback == null) {
                send(502, "Timeout");
            } else {
                callback(this);
            }
        }.bindenv(this))
    }
}

/****************** Firebase Classes *******************/
class Firebase {
    // General
    db = null;              // the name of your firebase
    auth = null;            // Auth key (if auth is enabled)
    baseUrl = null;         // Firebase base url
    prefixUrl = "";         // Prefix added to all url paths (after the baseUrl and before the Path)

    // For REST calls:
    defaultHeaders = { "Content-Type": "application/json" };

    // For Streaming:
    streamingHeaders = { "accept": "text/event-stream" };
    streamingRequest = null;    // The request object of the streaming request
    data = null;                // Current snapshot of what we're streaming
    callbacks = null;           // List of callbacks for streaming request

    keepAliveTimer = null;      // Wakeup timer that watches for a dead Firebase socket
    kaPath = null;              // stream parameters to allow a restart on keepalive
    kaOnError = null;

    /***************************************************************************
     * Constructor
     * Returns: FirebaseStream object
     * Parameters:
     *      baseURL - the base URL to your Firebase (https://username.firebaseio.com)
     *      auth - the auth token for your Firebase
     **************************************************************************/
    constructor(_db, _auth = null, domain = "firebaseio.com") {
        const KEEP_ALIVE = 60;

        db = _db;
        baseUrl = "https://" + db + "." + domain;
        auth = _auth;
        data = {};
        callbacks = {};
    }

    /***************************************************************************
     * Attempts to open a stream
     * Returns:
     *      false - if a stream is already open
     *      true -  otherwise
     * Parameters:
     *      path - the path of the node we're listending to (without .json)
     *      onError - custom error handler for streaming API
     **************************************************************************/
    function stream(path = "", onError = null) {
        // if we already have a stream open, don't open a new one
        if (isStreaming()) return false;

        // Keep a backup of these for future reconnects
        kaPath = path;
        kaOnError = onError;

        if (onError == null) onError = _defaultErrorHandler.bindenv(this);
        streamingRequest = http.get(_buildUrl(path), streamingHeaders);

        streamingRequest.sendasync(

            // This is called when the stream exits
            function (resp) {
                streamingRequest = null;
                if (resp.statuscode == 307 && "location" in resp.headers) {
                    // set new location
                    local location = resp.headers["location"];
                    local p = location.find(".firebaseio.com")+16;
                    baseUrl = location.slice(0, p);
                    // server.log("Redirecting to " + baseUrl);
                    return stream(path, onError);
                } else if (resp.statuscode == 28 || resp.statuscode == 429) {
                    // if we timed out, just reconnect after a small delay
                    imp.wakeup(1, function() {
                        return stream(path, onError);
                    }.bindenv(this))
                } else {
                    // Reconnect unless the stream after an error
                    server.error("Stream closed with error " + resp.statuscode);
                    imp.wakeup(1, function() {
                        return stream(path, onError);
                    }.bindenv(this))
                }
            }.bindenv(this),


            // This is called whenever there is new data
            function(messageString) {

                // Tickle the keep alive timer
                if (keepAliveTimer) imp.cancelwakeup(keepAliveTimer);
                keepAliveTimer = imp.wakeup(KEEP_ALIVE, _keepAliveExpired.bindenv(this))

                // server.log("MessageString: " + messageString);
                local messages = _parseEventMessage(messageString);
                foreach (message in messages) {
                    // Update the internal cache
                    _updateCache(message);

                    // Check out every callback for matching path
                    foreach (path,callback in callbacks) {

                        if (path == "/" || path == message.path || message.path.find(path + "/") == 0) {
                            // This is an exact match or a subbranch
                            callback(message.path, message.data);
                        } else if (message.event == "patch") {
                            // This is a patch for a (potentially) parent node
                            foreach (head,body in message.data) {
                                local newmessagepath = ((message.path == "/") ? "" : message.path) + "/" + head;
                                if (newmessagepath == path) {
                                    // We have found a superbranch that matches, rewrite this as a PUT
                                    local subdata = _getDataFromPath(newmessagepath, message.path, data);
                                    callback(newmessagepath, subdata);
                                }
                            }
                        } else if (message.path == "/" || path.find(message.path + "/") == 0) {
                            // This is the root or a superbranch for a put or delete
                            local subdata = _getDataFromPath(path, message.path, data);
                            callback(path, subdata);
                        } else {
                            // server.log("No match for: " + path + " vs. " + message.path);
                        }

                    }
                }
            }.bindenv(this),

            // Stay connected as long as possible
            NO_TIMEOUT

        );

        // Tickle the keepalive timer
        if (keepAliveTimer) imp.cancelwakeup(keepAliveTimer);
        keepAliveTimer = imp.wakeup(KEEP_ALIVE, _keepAliveExpired.bindenv(this))

        // server.log("New stream successfully started")

        // Return true if we opened the stream
        return true;
    }


    /***************************************************************************
     * Returns whether or not there is currently a stream open
     * Returns:
     *      true - streaming request is currently open
     *      false - otherwise
     **************************************************************************/
    function isStreaming() {
        return (streamingRequest != null);
    }

    /***************************************************************************
     * Closes the stream (if there is one open)
     **************************************************************************/
    function closeStream() {
        if (streamingRequest) {
            // server.log("Closing stream")
            streamingRequest.cancel();
            streamingRequest = null;
        }
    }

    /***************************************************************************
     * Registers a callback for when data in a particular path is changed.
     * If a handler for a particular path is not defined, data will change,
     * but no handler will be called
     *
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're listending to (without .json)
     *      callback - a callback function with two parameters (path, change) to be
     *                 executed when the data at path changes
     **************************************************************************/
    function on(path, callback) {
        if (path.len() > 0 && path.slice(0, 1) != "/") path = "/" + path;
        if (path.len() > 1 && path.slice(-1) == "/") path = path.slice(0, -1);
        callbacks[path] <- callback;
    }

    /***************************************************************************
     * Reads a path from the internal cache. Really handy to use in an .on() handler
     **************************************************************************/
    function fromCache(path = "/") {
        local _data = data;
        foreach (step in split(path, "/")) {
            if (step == "") continue;
            if (step in _data) _data = _data[step];
            else return null;
        }
        return _data;
    }

    /***************************************************************************
     * Reads data from the specified path, and executes the callback handler
     * once complete.
     *
     * NOTE: This function does NOT update firebase.data
     *
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're reading
     *      callback - a callback function with one parameter (data) to be
     *                 executed once the data is read
     **************************************************************************/
     function read(path, callback = null) {
        http.get(_buildUrl(path), defaultHeaders).sendasync(function(res) {
            if (callback) {
                local data = null;
                try {
                    data = http.jsondecode(res.body);
                } catch (err) {
                    server.error("Read: JSON Error: " + res.body);
                    return;
                }
                callback(data);
            } else if (res.statuscode != 200) {
                server.error("Read: Firebase response: " + res.statuscode + " => " + res.body)
            }
        }.bindenv(this));
    }

    /***************************************************************************
     * Pushes data to a path (performs a POST)
     * This method should be used when you're adding an item to a list.
     *
     * NOTE: This function does NOT update firebase.data
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're pushing to
     *      data     - the data we're pushing
     **************************************************************************/
    function push(path, data, priority = null, callback = null) {
        if (priority != null && typeof data == "table") data[".priority"] <- priority;
        http.post(_buildUrl(path), defaultHeaders, http.jsonencode(data)).sendasync(function(res) {
            if (callback) callback(res);
            else if (res.statuscode != 200) {
                server.error("Push: Firebase responded " + res.statuscode + " to changes to " + path)
            }
        }.bindenv(this));
    }

    /***************************************************************************
     * Writes data to a path (performs a PUT)
     * This is generally the function you want to use
     *
     * NOTE: This function does NOT update firebase.data
     *
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're writing to
     *      data     - the data we're writing
     **************************************************************************/
    function write(path, data, callback = null) {
        http.put(_buildUrl(path), defaultHeaders, http.jsonencode(data)).sendasync(function(res) {
            if (callback) callback(res);
            else if (res.statuscode != 200) {
                server.error("Write: Firebase responded " + res.statuscode + " to changes to " + path)
            }
        }.bindenv(this));
    }

    /***************************************************************************
     * Updates a particular path (performs a PATCH)
     * This method should be used when you want to do a non-destructive write
     *
     * NOTE: This function does NOT update firebase.data
     *
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're patching
     *      data     - the data we're patching
     **************************************************************************/
    function update(path, data, callback = null) {
        http.request("PATCH", _buildUrl(path), defaultHeaders, http.jsonencode(data)).sendasync(function(res) {
            if (callback) callback(res);
            else if (res.statuscode != 200) {
                server.error("Update: Firebase responded " + res.statuscode + " to changes to " + path)
            }
        }.bindenv(this));
    }

    /***************************************************************************
     * Deletes the data at the specific node (performs a DELETE)
     *
     * NOTE: This function does NOT update firebase.data
     *
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're deleting
     **************************************************************************/
    function remove(path, callback = null) {
        http.httpdelete(_buildUrl(path), defaultHeaders).sendasync(function(res) {
            if (callback) callback(res);
            else if (res.statuscode != 200) {
                server.error("Delete: Firebase responded " + res.statuscode + " to changes to " + path)
            }
        });
    }

    /************ Private Functions (DO NOT CALL FUNCTIONS BELOW) ************/
    // Builds a url to send a request to
    function _buildUrl(path) {
        // Normalise the /'s
        // baseURL = <baseURL>
        // prefixUrl = <prefixURL>/
        // path = <path>
        if (baseUrl.len() > 0 && baseUrl[baseUrl.len()-1] == '/') baseUrl = baseUrl.slice(0, -1);
        if (prefixUrl.len() > 0 && prefixUrl[0] == '/') prefixUrl = prefixUrl.slice(1);
        if (prefixUrl.len() > 0 && prefixUrl[prefixUrl.len()-1] != '/') prefixUrl += "/";
        if (path.len() > 0 && path[0] == '/') path = path.slice(1);

        local url = baseUrl + "/" + prefixUrl + path + ".json";
        url += "?ns=" + db;
        if (auth != null) url = url + "&auth=" + auth;

        return url;
    }

    // Default error handler
    function _defaultErrorHandler(errors) {
        foreach (error in errors) {
            server.error("ERROR " + error.code + ": " + error.message);
        }
    }

    // No keep alive has been seen for a while, lets reconnect
    function _keepAliveExpired() {
        keepAliveTimer = null;
        server.error("Keep alive timer expired. Reconnecting stream.")
        closeStream();
        stream(kaPath, kaOnError);
    }

    // parses event messages
    function _parseEventMessage(text) {

        // split message into parts
        local alllines = split(text, "\n");
        if (alllines.len() < 2) return [];

        local returns = [];
        for (local i = 0; i < alllines.len(); ) {
            local lines = [];

            lines.push(alllines[i++]);
            lines.push(alllines[i++]);
            if (i < alllines.len() && alllines[i+1] == "}") {
                lines.push(alllines[i++]);
            }

            // Check for error conditions
            if (lines.len() == 3 && lines[0] == "{" && lines[2] == "}") {
                local error = http.jsondecode(text);
                server.error("Firebase error message: " + error.error);
                continue;
            }

            // get the event
            local eventLine = lines[0];
            local event = eventLine.slice(7);
            // server.log(event);
            if(event.tolower() == "keep-alive") continue;

            // get the data
            local dataLine = lines[1];
            local dataString = dataLine.slice(6);

            // pull interesting bits out of the data
            local d;
            try {
                d = http.jsondecode(dataString);
            } catch (e) {
                server.error("Exception while decoding (" + dataString.len() + " bytes): " + dataString);
                throw e;
            }

            // return a useful object
            returns.push({ "event": event, "path": d.path, "data": d.data });
        }

        return returns;
    }

    // Updates the local cache
    function _updateCache(message) {

        // server.log(http.jsonencode(message));

        // base case - refresh everything
        if (message.event == "put" && message.path == "/") {
            data = (message.data == null) ? {} : message.data;
            return data
        }

        local pathParts = split(message.path, "/");
        local key = pathParts.len() > 0 ? pathParts[pathParts.len()-1] : null;

        local currentData = data;
        local parent = data;
        local lastPart = "";

        // Walk down the tree following the path
        foreach (part in pathParts) {
            if (typeof currentData != "array" && typeof currentData != "table") {
                // We have orphaned a branch of the tree
                if (lastPart == "") {
                    data = {};
                    parent = data;
                    currentData = data;
                } else {
                    parent[lastPart] <- {};
                    currentData = parent[lastPart];
                }
            }

            parent = currentData;

            // NOTE: This is a hack to deal with a quirk of Firebase
            // Firebase sends arrays when the indicies are integers and its more efficient to use an array.
            if (typeof currentData == "array") {
                part = part.tointeger();
            }

            if (!(part in currentData)) {
                // This is a new branch
                currentData[part] <- {};
            }
            currentData = currentData[part];
            lastPart = part;
        }

        // Make the changes to the found branch
        if (message.event == "put") {
            if (message.data == null) {
                // Delete the branch
                if (key == null) {
                    data = {};
                } else {
                    if (typeof parent == "array") {
                        parent[key.tointeger()] = null;
                    } else {
                        delete parent[key];
                    }
                }
            } else {
                // Replace the branch
                if (key == null) {
                    data = message.data;
                } else {
                    if (typeof parent == "array") {
                        parent[key.tointeger()] = message.data;
                    } else {
                        parent[key] <- message.data;
                    }
                }
            }
        } else if (message.event == "patch") {
            foreach(k,v in message.data) {
                if (key == null) {
                    // Patch the root branch
                    data[k] <- v;
                } else {
                    // Patch the current branch
                    parent[key][k] <- v;
                }
            }
        }

        // Now clean up the tree, removing any orphans
        _cleanTree(data);
    }

    // Cleans the tree by deleting any empty nodes
    function _cleanTree(branch) {
        foreach (k,subbranch in branch) {
            if (typeof subbranch == "array" || typeof subbranch == "table") {
                _cleanTree(subbranch)
                if (subbranch.len() == 0) delete branch[k];
            }
        }
    }

    // Steps through a path to get the contents of the table at that point
    function _getDataFromPath(c_path, m_path, m_data) {

        // Make sure we are on the right branch
        if (m_path.len() > c_path.len() && m_path.find(c_path) != 0) return null;

        // Walk to the base of the callback path
        local new_data = m_data;
        foreach (step in split(c_path, "/")) {
            if (step == "") continue;
            if (step in new_data) {
                new_data = new_data[step];
            } else {
                new_data = null;
                break;
            }
        }

        // Find the data at the modified branch but only one step deep at max
        local changed_data = new_data;
        if (m_path.len() > c_path.len()) {
            // Only a subbranch has changed, pick the subbranch that has changed
            local new_m_path = m_path.slice(c_path.len())
            foreach (step in split(new_m_path, "/")) {
                if (step == "") continue;
                if (step in changed_data) {
                    changed_data = changed_data[step];
                } else {
                    changed_data = null;
                }
                break;
            }
        }

        return changed_data;
    }

}

const FIREBASENAME = "impofficesensors";
const FIREBASESECRET = "xN7NcUI76i0IN8t4Wlqj9BjnzEwmIS2OZabjjdJ8";

firebase <- Firebase(FIREBASENAME, FIREBASESECRET);

/******************** Bullwinkle Class *****************/
class Bullwinkle {
    _handlers = null;
    _sessions = null;
    _partner  = null;
    _history  = null;
    _timeout  = 10;
    _retries  = 1;


    // .........................................................................
    constructor() {
        const BULLWINKLE = "bullwinkle";

        _handlers = { timeout = null, receive = null };
        _partner  = is_agent() ? device : agent;
        _sessions = { };
        _history  = { };

        // Incoming message handler
        _partner.on(BULLWINKLE, _receive.bindenv(this));
    }


    // .........................................................................
    function send(command, params = null) {

        // Generate an unique id
        local id = _generate_id();

        // Create and store the session
        _sessions[id] <- Bullwinkle_Session(this, id, _timeout, _retries);

        return _sessions[id].send("send", command, params);
    }


    // .........................................................................
    function ping() {

        // Generate an unique id
        local id = _generate_id();

        // Create and store the session
        _sessions[id] <- Bullwinkle_Session(this, id, _timeout, _retries);

        // Send it
        return _sessions[id].send("ping");
    }


    // .........................................................................
    function is_agent() {
        return (imp.environment() == ENVIRONMENT_AGENT);
    }

    // .........................................................................
    static function _getCmdKey(cmd) {
        return BULLWINKLE + "_" + cmd;
    }

    // .........................................................................
    function on(command, callback) {
        local cmdKey = Bullwinkle._getCmdKey(command);

        if (cmdKey in _handlers) {
            _handlers[cmdKey] = callback;
        } else {
            _handlers[cmdKey] <- callback
        }
    }
    // .........................................................................
    function onreceive(callback) {
        _handlers.receive <- callback;
    }


    // .........................................................................
    function ontimeout(callback, timeout = null) {
        _handlers.timeout <- callback;
        if (timeout != null) _timeout = timeout;
    }


    // .........................................................................
    function set_timeout(timeout) {
        _timeout = timeout;
    }


    // .........................................................................
    function set_retries(retries) {
        _retries = retries;
    }


    // .........................................................................
    function _generate_id() {
        // Generate an unique id
        local id = null;
        do {
            id = math.rand();
        } while (id in _sessions);
        return id;
    }

    // .........................................................................
    function _is_unique(context) {

        // Clean out old id's from the history
        local now = time();
        foreach (id,t in _history) {
            if (now - t > 100) {
                delete _history[id];
            }
        }

        // Check the current context for uniqueness
        local id = context.id;
        if (id in _history) {
            return false;
        } else {
            _history[id] <- time();
            return true;
        }
    }

    // .........................................................................
    function _clone_context(ocontext) {
        local context = {};
        foreach (k,v in ocontext) {
            switch (k) {
                case "type":
                case "id":
                case "time":
                case "command":
                case "params":
                    context[k] <- v;
            }
        }
        return context;
    }


    // .........................................................................
    function _end_session(id) {
        if (id in _sessions) {
            delete _sessions[id];
        }
    }


    // .........................................................................
    function _receive(context) {
        local id = context.id;
        switch (context.type) {
            case "send":
            case "ping":
                // build the command string
                local cmdKey = Bullwinkle._getCmdKey(context.command);

                // Immediately ack the message
                local response = { type = "ack", id = id, time = Bullwinkle_Session._timestamp() };
                if (!_handlers.receive && !_handlers[cmdKey]) {
                    response.type = "nack";
                }
                _partner.send(BULLWINKLE, response);

                // Then handed on to the callback
                if (context.type == "send" && (_handlers.receive || _handlers[cmdKey]) && _is_unique(context)) {
                    try {
                        // Prepare a reply function for shipping a reply back to the sender
                        context.reply <- function (reply) {
                            local response = { type = "reply", id = id, time = Bullwinkle_Session._timestamp() };
                            response.reply <- reply;
                            _partner.send(BULLWINKLE, response);
                        }.bindenv(this);

                        // Fire the callback
                        if (_handlers[cmdKey]) {
                            _handlers[cmdKey](context);
                        } else {
                            _handlers.receive(context);
                        }
                    } catch (e) {
                        // An unhandled exception should be sent back to the sender
                        local response = { type = "exception", id = id, time = Bullwinkle_Session._timestamp() };
                        response.exception <- e;
                        _partner.send(BULLWINKLE, response);
                    }
                }
                break;

            case "nack":
            case "ack":
                // Pass this packet to the session handler
                if (id in _sessions) {
                    _sessions[id]._ack(context);
                }
                break;

            case "reply":
                // This is a reply for an sent message
                if (id in _sessions) {
                    _sessions[id]._reply(context);
                }
                break;

            case "exception":
                // Pass this packet to the session handler
                if (id in _sessions) {
                    _sessions[id]._exception(context);
                }
                break;

            default:
                throw "Unknown context type: " + context.type;

        }
    }

}
class Bullwinkle_Session {
    _handlers = null;
    _parent = null;
    _context = null;
    _timer = null;
    _timeout = null;
    _acked = false;
    _retries = null;

    // .........................................................................
    constructor(parent, id, timeout = 0, retries = 1) {
        _handlers = { ack = null, reply = null, timeout = null, exception = null };
        _parent = parent;
        _timeout = timeout;
        _retries = retries;
        _context = { time = _timestamp(), id = id };
    }

    // .........................................................................
    function onack(callback) {
        _handlers.ack = callback;
        return this;
    }

    // .........................................................................
    function onreply(callback) {
        _handlers.reply = callback;
        return this;
    }

    // .........................................................................
    function ontimeout(callback) {
        _handlers.timeout = callback;
        return this;
    }

    // .........................................................................
    function onexception(callback) {
        _handlers.exception = callback;
        return this;
    }

    // .........................................................................
    function send(type = "resend", command = null, params = null) {

        _retries--;

        if (type != "resend") {
            _context.type <- type;
            _context.command <- command;
            _context.params <- params;
        }

        if (_timeout > 0) _set_timer(_timeout);
        _parent._partner.send(BULLWINKLE, _context);

        return this;
    }

    // .........................................................................
    function _set_timer(timeout) {

        // Stop any current timers
        _stop_timer();

        // Start a fresh timer
        _timer = imp.wakeup(_timeout, _ontimeout.bindenv(this));
    }

    // .........................................................................
    function _ontimeout() {

        // Close down the timer and session
        _timer = null;

        if (!_acked && _retries > 0) {
            // Retry is required
            send();
        } else {
            // Close off this dead session
            _parent._end_session(_context.id)

            // If we are still waiting for an ack, throw a callback
            if (!_acked) {
                _context.latency <- _timestamp_diff(_context.time, _timestamp());
                if (_handlers.timeout) {
                    // Send the context to the session timeout handler
                    _handlers.timeout(_context);
                } else if (_parent._handlers.timeout) {
                    // Send the context to the global timeout handler
                    _parent._handlers.timeout(_context);
                }
            }
        }
    }

    // .........................................................................
    function _stop_timer() {
        if (_timer) imp.cancelwakeup(_timer);
        _timer = null;
    }

    // .........................................................................
    function _timestamp() {
        if (Bullwinkle.is_agent()) {
            local d = date();
            return format("%d.%06d", d.time, d.usec);
        } else {
            local d = math.abs(hardware.micros());
            return format("%d.%06d", d/1000000, d%1000000);
        }
    }


    // .........................................................................
    function _timestamp_diff(ts0, ts1) {
        // server.log(ts0 + " > " + ts1)
        local t0 = split(ts0, ".");
        local t1 = split(ts1, ".");
        local diff = (t1[0].tointeger() - t0[0].tointeger()) + (t1[1].tointeger() - t0[1].tointeger()) / 1000000.0;
        return math.fabs(diff);
    }


    // .........................................................................
    function _ack(context) {
        // Restart the timeout timer
        _set_timer(_timeout);

        // Calculate the round trip latency and mark the session as acked
        _context.latency <- _timestamp_diff(_context.time, _timestamp());
        _acked = true;

        // Fire a callback
        if (_handlers.ack) {
            _handlers.ack(_context);
        }

    }


    // .........................................................................
    function _reply(context) {
        // We can stop the timeout timer now
        _stop_timer();

        // Fire a callback
        if (_handlers.reply) {
            _context.reply <- context.reply;
            _handlers.reply(_context);
        }

        // Remove the history of this message
        _parent._end_session(_context.id)
    }


    // .........................................................................
    function _exception(context) {
        // We can stop the timeout timer now
        _stop_timer();

        // Fire a callback
        if (_handlers.exception) {
            _context.exception <- context.exception;
            _handlers.exception(_context);
        }

        // Remove the history of this message
        _parent._end_session(_context.id)
    }

}

//initialize Bullwinkle
bullwinkle <- Bullwinkle();

/******************** API Class ************************/
class AgentSensorAPI {
    _agentID = null;
    _bullwinkle = null;
    _sensorSettings = null;
    _settingsChanged = false;
    _broadcastCallback = null;

    constructor(readingInterval, reportingInterval, bullwinkle, broadcastCallback=null) {
        _agentID = split(http.agenturl(), "/").pop();
        _bullwinkle = bullwinkle;
        _broadcastCallback = broadcastCallback;
        _sensorSettings = { "agentID" : _agentID,
                            "reportingInterval" : reportingInterval,
                            "readingInterval" : readingInterval,
                            "channels" : [] };
        init();
    }

    function init() {
        _bullwinkle.on("getSettings", _sendSettings.bindenv(this));
        _bullwinkle.on("sendData", function(context) { _broadcastData(context, _broadcastCallback) }.bindenv(this));
        _bullwinkle.on("ack", _successfulCommunicationResponse.bindenv(this));
    }

    function configureChannel (type, availStreams=[], availEvents={}) {
        if(typeof availStreams != "array" && typeof availStreams == "table") {
            availEvents = availStreams;
            availStreams = [];
        }
        if(typeof availEvents != "table" && typeof availEvents == "array") {
            availStreams = availEvents;
            availEvents = {};
        }
        if(typeof type == "string" && typeof availStreams == "array" && typeof availEvents == "table") {
            local id = _sensorSettings.channels.len();
            _sensorSettings.channels.push({ "channelID" : id,
                                          "type" : type,
                                          "active" : false,
                                          "availableStreams" : availStreams,
                                          "availableEvents" : availEvents,
                                          "activeStreams" : [],
                                          "activeEvents" : {} });
        } else {
            server.log("Parameters not of the correct type");
        }
    }

    function setBroadcastCallback(callback) {
        _broadcastCallback = callback;
    }

    function getChannels() {
        return http.jsonencode(_sensorSettings);
    }

    // subscribe to 1, some, or all channel streams
    // takes an array of channelIDs as a parameter (if no parameter then will subscribe to all channels)
    function activateChannels(channelIDs=null) {
        //if no channelID given create an array of all channelIDs
        if(!channelIDs) { channelIDs = _createchannelIDArray(); }
        foreach(cID in channelIDs) {
            _sensorSettings.channels[cID].activeStreams = _sensorSettings.channels[cID].availableStreams;
            //change status to active if it isn't
            if( _sensorSettings.channels[cID].activeStreams.len() > 0 && !(_sensorSettings.channels[cID].active) ) {
                _sensorSettings.channels[cID].active = true;
            }
            _settingsChanged = true;
        }
    }

    //subscribe to a specific stream
    function activateStream(channelID, stream) {
        if(stream in _sensorSettings.channels[channelID].availableStreams) {
            _sensorSettings.channels[channelID].activeStreams.push(stream);
            _sensorSettings.channels[cID].active = true;
            _settingsChanged = true;
        }
    }

    // subscribe to specific event
    // example parameters - (1, "sensorTail_themostat", {"low":20, "high":30})
    // if no eventParams are passed in then default params for event will be used
    function activateEvent(channelID, event, eventParams=null) {
        if(event in _sensorSettings.channels[channelID].availableEvents) {
            if(eventParams == null) { eventParams = _sensorSettings.channels[channelID].availableEvents[event] };
            _sensorSettings.channels[channelID].activeEvents[event] <- eventParams;
            _sensorSettings.channels[channelID].active = true;
            _settingsChanged = true;
        }
    }

    //subscribes to all streams & events with default settings
    function activateAll() {
        local channelIDs = _createchannelIDArray();
        foreach(cID in channelIDs) {
            _sensorSettings.channels[cID].activeStreams = _sensorSettings.channels[cID].availableStreams;
            _sensorSettings.channels[cID].activeEvents = _sensorSettings.channels[cID].availableEvents;
            //change status to active if it isn't
            if( !(_sensorSettings.channels[cID].active) && (_sensorSettings.channels[cID].activeStreams.len() > 0 || _sensorSettings.channels[cID].activeEvents.len() > 0) ) {
                _sensorSettings.channels[cID].active = true;
            }
            _settingsChanged = true;
        }
    }

    //unsubscribes from all streams & events
    function deactivateAll() {
        local channelIDs = _createchannelIDArray();
        foreach(cID in channelIDs) {
            _sensorSettings.channels[cID].activeStreams = {};
            _sensorSettings.channels[cID].activeEvents = {};
            if(_sensorSettings.channels[cID].active) { _sensorSettings.channels[cID].active = false };
            _settingsChanged = true;
        }
    }

    // unsubscribe to 1, some, all channel streams
    // takes an array of channelIDs as a parameter (if no parameter then will unsubscribe from all channel streams)
    function deactivateChannels(channelIDs=null) {
        if(!channelIDs) { channelIDs = _createchannelIDArray() };
        foreach(cID in channelIDs) {
            _sensorSettings.channels[cID].activeStreams = {};
            if(_sensorSettings.channels[cID].active && _sensorSettings.channels[cID].activeStreams.len() == 0 && _sensorSettings.channels[cID].activeEvents.len() == 0) {
                _sensorSettings.channels[cID].active = false;
            }
            _settingsChanged = true;
        }
    }

    //unsubscribes from a specific stream
    function deactivateStream(channelID, stream) {
        if(stream in _sensorSettings.channels[channelID].activeStreams) {
            _sensorSettings.channels[channelID].activeStreams.remove( _sensorSettings.channels[channelID].activeStreams.find(stream) );
            if(_sensorSettings.channels[channelID].active && _sensorSettings.channels[channelID].activeStreams.len() == 0 && _sensorSettings.channels[channelID].activeEvents.len() == 0) {
                _sensorSettings.channels[channelID].active = false;
            }
            _settingsChanged = true;
        }
    }

    //unsubscribes from a specific event
    function deactivateEvent(channelID, event) {
        if(event in _sensorSettings.channels[channelID].activeEvents) {
            _sensorSettings.channels[channelID].activeEvents.rawdelete(event);
            if(_sensorSettings.channels[channelID].active && _sensorSettings.channels[channelID].activeStreams.len() == 0 && _sensorSettings.channels[channelID].activeEvents.len() == 0) {
                _sensorSettings.channels[channelID].active = false;
            }
            _settingsChanged = true;
        }
    }

    // change reporting interval for device
    // this should be multiple of readingInterval
    function updateReportingInterval(newReportInt) {
        if(_sensorSettings.reportingInterval != newReportInt) {
            _sensorSettings.reportingInterval = newReportInt;
            _settingsChanged = true;
        }
    }

    // changes the reading interval for device
    // this should be a factor of reportingInterval
    function updateReadingInterval(newReadInt) {
        if(_sensorSettings.readingInterval != newReadInt) {
            _sensorSettings.readingInterval = newReadInt;
            _settingsChanged = true;
        }
    }

    function updateEventParams(channelID, event, params) {
        if(_sensorSettings["sensors"].len() > channelID && event in _sensorSettings["sensors"][channelID]["availableEvents"]) {
            _sensorSettings["sensors"][channelID]["availableEvents"][event] = params;
            _settingsChanged = true;
        }
    }

    function _sendSettings(context) {
        context.reply(_getActiveSensorSettings());
    }

    function _broadcastData(context, callback=null) {
        // if settings have changed send new settings
        _settingsChanged ? context.reply(_getActiveSensorSettings()) : context.reply(null);

        if(context.params) { //we got data
            if(callback) { callback(context.params) };
        }
    }

    function _successfulCommunicationResponse(context) {
        _settingsChanged = false;
        context.reply("OK");
    }

    //builds table of active subscriptions to send to device
    function _getActiveSensorSettings() {
        local activeSensorSettings = { "reportingInterval" : _sensorSettings.reportingInterval,
                                      "readingInterval" : _sensorSettings.readingInterval,
                                      "subscriptions" : {} };
        foreach(sensor in _sensorSettings.channels) {
            if(sensor.active) {
                if(sensor.activeStreams.len() > 0) {
                    if (!("activeStreams" in activeSensorSettings["subscriptions"])) {
                        activeSensorSettings["subscriptions"]["activeStreams"] <- [];
                    }
                    foreach(stream in sensor.activeStreams) {
                        activeSensorSettings["subscriptions"]["activeStreams"].push(stream)
                    }
                }
                if(sensor.activeEvents.len() > 0) {
                    if (!("activeEvents" in activeSensorSettings["subscriptions"])) {
                        activeSensorSettings["subscriptions"]["activeEvents"] <- {};
                    }
                    foreach(event, params in sensor.activeEvents){
                        activeSensorSettings["subscriptions"]["activeEvents"][event] <- params;
                    }
                }
            }
        }
        // server.log(http.jsonencode(activeSensorSettings))
        return activeSensorSettings;
    }

    //helper for subscription events for all sensors
    function _createchannelIDArray() {
        local ids = [];
            for (local i = 0; i < _sensorSettings.channels.len(); i++) {
                ids.push(i);
            }
        return ids;
    }
}


/******************* Initialize API ********************/

//time in sec that the imp sleeps between data collection for streams
readingInterval <- 15;

//time in sec that the imp waits between connection to agent
//this should be a multiple of the readingInterval
reportingInterval <- 60;

//initialize our communication class
api <- AgentSensorAPI(readingInterval, reportingInterval, bullwinkle);


/******************* Configure Channels ********************/
/*  configure a channel
    params -
        string - description of sensor data type,
        array - contains stream "command names"
        table - keys are event "command names" : values are the parameters for event

    notes - the "command names" need to match the device side "command names" in sensorSubscriptionFunctionsByCommand table
          - parameters can be set up in any format so long as it matches the device side code you have written */
api.configureChannel("temp", ["noraTemp_tempReadings"], {"noraTemp_thermostat" : {"low": 27, "high": 28}});
api.configureChannel("tempHumid", ["noraTempHumid_tempReadings", "noraTempHumid_humidReadings"]);
api.configureChannel("ambLight", ["noraAmbLight_lightReadings"]);

/******************* API Firebase Integration for data streaming ***************/
agentID <- split(http.agenturl(), "/").pop();

/**** Set Up Firebase Listeners ****/
function updateSettings(path, data) {
    local path = split(path, "/")
    local editedNode = path.top();

    if(path.len() == 1 && data) {
        //we just created an active or inactive route
        foreach(item, info in data) {
            updateChannel(editedNode, item, info)
        }
    }

    if(path.len() == 2 && data) {
        //we just updated a stream/event
        updateChannel(path[0], editedNode, data);
    }
}

function updateChannel(pNode, commandName, data) {
    local channel = data.channelID.tointeger();
    if (pNode.find("inactive") != null) {
        if(pNode.find("Streams") != null) {
            firebase.remove("settings/"+agentID+"/activeStreams/"+commandName);
            api.deactivateStream(channel, commandName);
        } else {
            firebase.remove("settings/"+agentID+"/activeEvents/"+commandName);
            api.deactivateEvent(channel, commandName);
        }
    } else {
         if(pNode.find("Streams") != null) {
             firebase.remove("settings/"+agentID+"/inactiveStreams/"+commandName);
             api.activateStream(channel, commandName);
        } else {
            firebase.remove("settings/"+agentID+"/inactiveEvents/"+commandName);
            api.activateEvent(channel, commandName);
        }
    }
}

function updateInterval(path, data) {
    local node = split(path, "/").pop();
    if (data && node == "readingInterval") {
        api.updateReadingInterval(data.tointeger());
        server.log("updating Reading Interval to "+data);
    }
    if (data && node == "reportingInterval") {
        api.updateReportingInterval(data.tointeger());
        server.log("updating Reporting Interval to "+data);
    }
}

firebase.on("/inactiveEvents", updateSettings)
firebase.on("/inactiveStreams", updateSettings)
firebase.on("/activeEvents", updateSettings)
firebase.on("/activeStreams", updateSettings)
firebase.on("/readingInterval", updateInterval)
firebase.on("/reportingInterval", updateInterval)

firebase.stream("/settings/"+agentID, true);

/**** Send Current Settings To Firebase ****/
function writeSettingsToFB() {
    firebase.remove("/settings/"+agentID);
    local settings = http.jsondecode(api.getChannels());
    firebase.update("/settings/"+agentID, {"reportingInterval" : settings.reportingInterval, "readingInterval" : settings.readingInterval});

    foreach (channel in settings.channels) {
        firebase.update("/settings/"+agentID+"/channels/"+channel.channelID, {"type" : channel.type});

        foreach (stream in channel.availableStreams) {
            if (channel.activeStreams.find(stream) == null) {
                firebase.update("/settings/"+agentID+"/inactiveStreams/"+stream, {"channelID" : channel.channelID});
            } else {
                firebase.remove("/settings/"+agentID+"/inactiveStreams/"+stream);
            }
        }
        foreach (event, params in channel.availableEvents) {
            if (event in channel.activeEvents) {
                firebase.remove("/settings/"+agentID+"/inactiveEvents/"+event);
            } else {
                firebase.update("/settings/"+agentID+"/inactiveEvents/"+event, {"channelID" : channel.channelID, "params" : params});
            }
        }
        foreach (stream in channel.activeStreams) {
            firebase.update("/settings/"+agentID+"/activeStreams/"+stream, {"channelID" : channel.channelID});
            firebase.remove("/settings/"+agentID+"/inactiveStreams/"+stream);
        }
        foreach (event, params in channel.activeEvents) {
            firebase.update("/settings/"+agentID+"/activeEvents/"+event, {"channelID" : channel.channelID, "params" : params});
            firebase.remove("/settings/"+agentID+"/inactiveEvents/"+event);
        }
    }
}

/**** Handle Data From Device ****/

//sort readings by timestamp - make sure your timestamp label matches device code
function buildQue(stream, readings, location, callback) {
    local que = [];
    foreach (reading in readings) {
        que.push(reading);
    }
    que.sort(function (a, b) { return b.ts <=> a.ts });
    callback(stream, que, location);
}

//loop that writes readings to db in order by timestamp
function writeQueToDB(stream, que, location) {
    local reading;
    if (que.len() > 0) {
        reading = que.pop();
        // server.log("Agent ID: "+agentid+" Temperature: "+reading.t+" Time: "+reading.ts+" Location: "+location);
        firebase.push("/data/"+location+"/"+agentID+"/"+stream, reading, null, function(res) { writeQueToDB(stream, que, location) });
    }
}

// Use #setBroadcastCallback from api class to parse data from device & write to firebase
api.setBroadcastCallback(function(data) {
    firebase.read("/devices/"+agentID+"/location", function(location){
        foreach (stream, readings in data) {
            buildQue(stream, readings, location, writeQueToDB);
        }
    });
});




/********************* RUN TIME TESTS ***************************/
server.log("Agent Running");

//subscribe to everything
server.log(api.getChannels());
api.activateChannels([2, 0])
// api.activateEvent(0, "noraTemp_thermostat");
server.log(api.getChannels());

//call this anytime you make a change in the agent that wants to be pushed to firebase
writeSettingsToFB();

//change reading and reporting intervals
imp.wakeup(50, function() {
    api.updateReadingInterval(60);
    api.updateReportingInterval(300);
    writeSettingsToFB();
}.bindenv(api));











//data structure examples - these are for me-ignore!!!

//agent to device table
/*activeSensorSettings <- { "reportingInterval" : reportingInterval,
                          "readingInterval" : readingInterval,
                          "subscriptions" : { "activeStreams" : [ "SI7021_sensorTail_tempReadings" ],
                                              "activeEvents" : {"SI7021_sensorTail_themostat" : {"low":20, "high":30} }
                        }

*/

//device side nv table
/*nv:   { envSensorTailData: {  "nextWakeUp": 1422306809,
                                "nextConnection": 1422306864,
                                "sensorReadings": { "sensorTail_tempReadings" : [ readings... ],
                                                    "sensorTail_themostat" : [ readings... ] },
                              },
          envSensorTailSettings: {  readingInterval: 5,
                                    reportingInterval: 60,
                                    subscriptions: {
                                        "activeStreams" : [ "sensorTail_tempReadings",
                                                            "sensorTail_humidReadings"],
                                        "activeEvents" : { "sensorTail_themostat" : {low: 20, high: 30} }
                                    }
                                 },
          eventPins: {"pinE":null},
          eventConfig: { "noraTemp_thermostat" : {"pin" : "pinE", "eventTriggerPolarity" : 0, "callback" : function(){ initializeTemp(); return noraTemp.readTempC();} },
                     "nora_baro" : {"pin" : "pinA", "eventTriggerPolarity" : 1, "callback" : function(){server.log("barometer event")} },
                     "nora_accel" : {"pin" : "pinB", "eventTriggerPolarity" : 1, "callback" : function(){server.log("accel event")} },
                     "nora_mag" : {"pin" : "pinC", "eventTriggerPolarity" : 0, "callback" : function(){server.log("mag event")} },
                     "nora_als" : {"pin" : "pinD", "eventTriggerPolarity" : 0, "callback" : function(){server.log("als event")} },
                    }
        }
*/


// _eventTracker = { "triggered" : false,
//                       "events" : [] };