#require "Bullwinkle.class.nut:1.0.0"

/******************** Bullwinkle Class *****************/
//initialize Bullwinkle
bullwinkle <- Bullwinkle();

/******************** API Class ************************/
// Requires bullwinkle
// Used to create a pub/sub stream of sensor data between device and agent.
// The api classes support subscriptions to data stream and event channels.
// Communication is based on channel names. These are unique strings used to identify each channel a user can subscribe to.

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
        if(_sensorSettings.channels[channelID].availableStreams.find(stream) != null) {
            if(_sensorSettings.channels[channelID].activeStreams.find(stream) == null) {
                _sensorSettings.channels[channelID].activeStreams.push(stream);
                _sensorSettings.channels[channelID].active = true;
                _settingsChanged = true;
            }
        } else {
            server.log("didn't find stream")
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
        } else {
            server.log("didn't find event")
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
                        if (activeSensorSettings["subscriptions"]["activeStreams"].find(stream) == null) {
                            activeSensorSettings["subscriptions"]["activeStreams"].push(stream)
                        }
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
          - parameters should be in a table with keys that match your device side code */
api.configureChannel("temp", ["noraTemp_tempReadings"], {"noraTemp_thermostat" : {"low": 27, "high": 28}});
api.configureChannel("tempHumid", ["noraTempHumid_tempReadings", "noraTempHumid_humidReadings"]);
api.configureChannel("ambLight", ["noraAmbLight_lightReadings"]);



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

const FIREBASENAME = "<enter firebase name here>";
const FIREBASESECRET = "<enter firebase secret here>";

firebase <- Firebase(FIREBASENAME, FIREBASESECRET);


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
            server.log("deactivating "+commandName+" on channel " +channel+".")
        } else {
            firebase.remove("settings/"+agentID+"/activeEvents/"+commandName);
            api.deactivateEvent(channel, commandName);
            server.log("deactivating "+commandName+" on channel " +channel+".")
        }
    } else {
         if(pNode.find("Streams") != null) {
             firebase.remove("settings/"+agentID+"/inactiveStreams/"+commandName);
             api.activateStream(channel, commandName);
             server.log("activating "+commandName+" on channel " +channel+".")
        } else {
            firebase.remove("settings/"+agentID+"/inactiveEvents/"+commandName);
            api.activateEvent(channel, commandName);
            server.log("activating "+commandName+" on channel " +channel+".")
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
    local available = {};

    foreach (channel in settings.channels) {
        firebase.update("/settings/"+agentID+"/channels/"+channel.channelID, {"type" : channel.type});

        foreach (stream in channel.availableStreams) {
            available[stream] <- {"channelID" : channel.channelID};
            if (channel.activeStreams.find(stream) == null) {
                firebase.update("/settings/"+agentID+"/inactiveStreams/"+stream, {"channelID" : channel.channelID});
            } else {
                firebase.remove("/settings/"+agentID+"/inactiveStreams/"+stream);
            }
        }
        foreach (event, params in channel.availableEvents) {
            available[event] <- {"channelID" : channel.channelID};
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
    firebase.update("settings/"+agentID+"/", {"available" : available});
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
            server.log("stream: " + stream);
            server.log("readings: " + http.jsonencode(readings))
        }
    });
    server.log("writing data to FB");
});



/********************* RUN TIME TESTS ***************************/
server.log("Agent Running");

server.log(api.getChannels());
api.activateChannels([2, 1]);
server.log(api.getChannels());

//call this anytime you make a change in the agent that wants to be pushed to firebase
writeSettingsToFB();

//change reading and reporting intervals
imp.wakeup(50, function() {
    api.updateReadingInterval(60);
    api.updateReportingInterval(300);
    writeSettingsToFB();
}.bindenv(api));
