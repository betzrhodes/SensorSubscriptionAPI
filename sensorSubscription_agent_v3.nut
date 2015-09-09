#require "Bullwinkle.class.nut:1.0.0"

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

// Class for Streaming Sensor Data
// This class receives data from the device, and acts as a communication 
//  layer for interacting with the device.
// This class is dependent on bullwinkle class
// This class has 1 required parameter, and 1 optional parameter when initialized
    // 1st Parameter : instance of Bullwinkle
    // 2nd Parameter (optional) : a callback function for handling data from device
// This class has functions that 
    // get reading interval
    // get reporting interval
    // get available subscriptions info
    // get available subscrtiptions
    // get active subscriptions
    // get inactive subscriptions
    
    // update a reading interval (time between sensor readings in sec)
    // update a reporting interval (time between connection to agent in sec)
    // update broadcast callback
    
    // activate a subscription
    // deactivate a subscription
    // activate all subscriptions
    // deactivate all subscriptions
class SubscriptionManagerAgent {
    _bullwinkle = null;
    _broadcastCallback = null;
    
    _subscriptionSettings = null;
    _settingsFlag = null;
    
    constructor(bullwinkle, broadcastCallback=null) {
        _bullwinkle = bullwinkle;
        _broadcastCallback = broadcastCallback ? broadcastCallback : _defaultBroadcast;
        
        _subscriptionSettings = _getStoredSubSettings();
        _settingsFlag = false;
        
        _openListeners();
    }
    
    // Get Settings
    // Returns reading interval or null if no reading interval is not stored
    function getReadingInterval() {
        if("readingInterval" in _subscriptionSettings) {
            return _subscriptionSettings.readingInterval;
        } else {
            return null;
        }
    }
    
    // Returns reporting interval or null if no reporting interval is not stored
    function getReportingInterval() {
        if("reportingInterval" in _subscriptionSettings) {
            return _subscriptionSettings.reportingInterval;
        } else {
            return null;
        }
    }
    
    // Returns current settings for all subscriptions
    function getSubscriptionsInfo() {
        if("settings" in _subscriptionSettings) {
            return _subscriptionSettings.settings;
        } else {
            return {};
        }
    }
    
    // Returns array of subscription names for all active subscriptions
    function getActiveSubscriptions() {
        local activeSubs = [];
        if("settings" in _subscriptionSettings) {
            foreach(sub, info in _subscriptionSettings.settings) {
                if(_subscriptionSettings.settings[sub]["subscribedTo"] == true) {
                    activeSubs.push(sub);
                }
            }
        }
        return activeSubs;
    }
    
    function getInactiveSubscriptions() {
        local inactiveSubs = [];
        if("settings" in _subscriptionSettings) {
            foreach(sub, info in _subscriptionSettings.settings) {
                if(_subscriptionSettings.settings[sub]["subscribedTo"] == false) {
                    inactiveSubs.push(sub);
                }
            }
        }
        return inactiveSubs;
    }
    
    // Returns array of subscription names for all subscriptions
    function getAvailableSubscriptions() {
        local activeSubs = [];
        if("settings" in _subscriptionSettings) {
            foreach(sub, info in _subscriptionSettings.settings) {
                activeSubs.push(sub);
            }
        }
        return activeSubs;
    }
    
    // Update Settings
    // Updates reading interval in local table and server
    function updateReadingInterval(newReadingInt) {
        _subscriptionSettings.readingInterval <- newReadingInt;
        _updateStoredSubSettings(_subscriptionSettings);
        _settingsFlag = true;
    }
    
    // Updates reporting interval in local table and server
    function updateReportingInterval(newReportingInt) {
        _subscriptionSettings.reportingInterval <- newReportingInt;
        _updateStoredSubSettings(_subscriptionSettings);
        _settingsFlag = true;
    }
    
    // Sets broadcastCallback to function that is passed in
    function updateBroadcastCallback(newCallback) {
        _broadcastCallback = newCallback;
    }
    
    
    // Subscription Functions
    function subscribe(subName) {
        if(!_subscriptionSettings.settings[subName]["subscribedTo"]) {
            _subscriptionSettings.settings[subName]["subscribedTo"] = true;
            _updateStoredSubSettings(_subscriptionSettings);
            _settingsFlag = true;
        }
    }
    
    function unsubscribe(subName) {
        if(_subscriptionSettings.settings[subName]["subscribedTo"]) {
            _subscriptionSettings.settings[subName]["subscribedTo"] = false;
            _updateStoredSubSettings(_subscriptionSettings);
            _settingsFlag = true;
        }
    }
    
    function subscribeToAll() {
        foreach(sub in getAvailableSubscriptions()) {
            _subscriptionSettings.settings[sub]["subscribedTo"] = true;
        }
        _updateStoredSubSettings(_subscriptionSettings);
        _settingsFlag = true;
    }
    
    function unsubscribeFromAll() {
        foreach(sub in getAvailableSubscriptions()) {
            _subscriptionSettings.settings[sub]["subscribedTo"] = false;
        }
        _updateStoredSubSettings(_subscriptionSettings);
        _settingsFlag = true;
    }
    
    ///////////////////////// Private Functions /////////////////////////
    
    // Opens bullwinkle settings and readings listeners
    function _openListeners() {
        _bullwinkle.on("getSubscriptionSettings", function(context) {
            context.reply(_subscriptionSettings);
        }.bindenv(this));

        _bullwinkle.on("sendDefaultSubscriptionSettings", function(context) {
            _subscriptionSettings = context.params;
            _updateStoredSubSettings(_subscriptionSettings);
            context.reply("OK");
        }.bindenv(this));
        
        _bullwinkle.on("sendReadings", function(context) {
            if(context.params) {
                _broadcastCallback(null, context.params);
            } else {
                _broadcastCallback("No Data", null);
            }
            
            if(_settingsFlag) {
                context.reply(_subscriptionSettings);
            } else {
                context.reply("OK");
            }
        }.bindenv(this));
        
        _bullwinkle.on("receivedSettings", function(context) {
            _settingsFlag = false;
        }.bindenv(this));
    }
    
    // Returns subscription settings stored on server or an empty table if no settings on server
    function _getStoredSubSettings() {
        local persist = server.load();
        if ("subscriptionSettings" in persist) {
            return persist.subscriptionSettings;
        } else {
            return {};
        }
    }
    
    // Stores new settings to server.subscriptionSettings
    function _updateStoredSubSettings(newSettings) {
        server.save({"subscriptionSettings" : newSettings});
    }
    
    function _defaultBroadcast(err, data) {
        if (err) { server.log(err); }
        if (data) { 
            foreach(sub, readings in data) {
                server.log(sub + ": " + http.jsonencode(readings)); 
            }
        }
    }
    
}
    
    
// Class to handle communication between agent and Firebase
// This class is customized to interact with a specific database & should not be reused
// This class is dependent on Firebase Class
// This class requires 2 parameters when initialized
    // 1st Parameter : instance of Firebase
    // 2nd Parameter : a table of callbacks for getting & setting subscription 
    //  settings, and for subscribing & unsubscribing from subscriptions
// This class has functions that 
    // Store given settings to Firebase
    // Store data to Firebase
    // Use Firebase to track subscription status
    // Update given settings in Firebase
    // Listens for changes to Firebase and updates the agent/device with changes
class FBManager {
    _fb = null;
    _subCallbacks = null;
    _agentID = null;
    _location = null;
    
    constructor(firebase, subCallbacks) {
        _fb = firebase;
        _subCallbacks = subCallbacks;
        _agentID = split(http.agenturl(), "/").pop();
        
        _openListeners();
    }

    // Stores agent side settings to Firebase/settings
    function storeSettings(readingInt, reportingInt, subSettings) {
        updateFBSetting("readingInterval", readingInt);
        updateFBSetting("reportingInterval", reportingInt);
        foreach(sub, settings in subSettings) {
            if("type" in settings) { 
                updateFBSetting("subscriptionSettings/"+sub+"/type", settings.type);
            }
            if("channel" in settings) { 
                updateFBSetting("subscriptionSettings/"+sub+"/channel", settings.channel);
            }
        }
    }

    // Stores agent side subscriptions to Firebase/locations
    function storeSubcriptions(callback=null) {
        if(_location) {
            local activeSubs = _subCallbacks.getActiveSubs(); 
            local inactiveSubs = _subCallbacks.getInactiveSubs();
            local data = { "active": {}, "inactive": {} };
        
            foreach(sub in activeSubs) {
                data.active[sub] = {"name" : sub, "widgets" : []};
            }
            foreach(sub in inactiveSubs) {
                data.inactive[sub] = {"name" : sub, "widgets" : []};
            }
            
            // Store subscriptions in Firebase locations node 
            _fb.write("/settings/locations/"+_location+"/"+_agentID, data);
        }
        
        if(callback) { callback(); }
    }
    
    // Stores readings to Firebase/data
    function storeReadings(err, data) {
        if (err) { server.log(err); }
        if (data && _location) { 
            foreach(subcription, readings in data) {
                _buildQue(subcription, readings, _writeQueToDB);
            }
        }
    }
    
    // Updates Firebase/settings with data passed in
    function updateFBSetting(settingNode, newSetting) {
        _fb.write("/settings/devices/"+_agentID+"/"+settingNode, newSetting);
    }
    
    
    ////////////////////////////// Private Functions /////////////////////////
    
    // Sort readings by timestamp - make sure your timestamp label matches device code
    function _buildQue(subscription, readings, callback) {
        readings.sort(function (a, b) { return b.ts <=> a.ts });
        callback(subscription, readings);
    }
    
    // Loop that writes readings to db in order by timestamp
    function _writeQueToDB(subscription, que) {
        if (que.len() > 0) {
            local reading = que.pop();
            _fb.push("/data/"+_location+"/"+_agentID+"/"+subscription, reading, null, function(res) { _writeQueToDB(subscription, que); }.bindenv(this));
        }
    }
    
    // Updates subscriptions with response from FB locations listener
    function _updateSubscriptions(path, res) {
        if(res != null) {
            local path = split(path, "/");
            local editedNode = path.top();
            
            if(editedNode == _agentID) {
                if("active" in res) {
                    foreach(sub, info in res.active) {
                        _subCallbacks.subscribe(sub);
                    }                    
                }
                if("inactive" in res) {
                    foreach(sub, info in res.inactive) {
                        _subCallbacks.unsubscribe(sub);
                    }
                }
            }
            
            if(editedNode == "active" && res != null) {
                foreach(sub, info in res) {
                    _subCallbacks.subscribe(sub);
                }
            }
            if(editedNode == "inactive" && res != null) {
                foreach(sub, info in res) {
                    _subCallbacks.unsubscribe(sub);
                }
            }
        }
    }
    
    // Updates the location with response from FB devices listener
    function _updateLocation(path, res) {
        if(res == null && _location == null) {
            // Device not in Dashboard. Send agent settings to Firebase.
            _sendAgentSettings();
            //unsubscribe from all
            local subs = _subCallbacks.getActiveSubs();
            foreach(sub in subs) {
                _subCallbacks.unsubscribe(sub);
            }
        } else { 
            // Device added to Dashboard. Set location & open listener
            if(_location == null) {
                _location = res;
                _fb.on("/locations/"+_location+"/"+_agentID, _updateSubscriptions.bindenv(this));
            }
            // Location has changed. Update location and listeners
            if(res != _location)  {
                // Close listener on old location
                _fb.on("/locations/"+_location+"/"+_agentID, null);
                // update location
                _location = res;
                
                // we deleted a device from the dashboard unsubscribe
                if(_location == null) {
                    //unsubscribe from all
                    local subs = _subCallbacks.getActiveSubs();
                    foreach(sub in subs) {
                        _subCallbacks.unsubscribe(sub);
                    }
                // we moved a device to new location - open a listener for that location
                } else {
                    _fb.on("/locations/"+_location+"/"+_agentID, _updateSubscriptions.bindenv(this));
                }
            }
        }
    }
    
    // Updates FB with local settings
    function _sendAgentSettings() {
        storeSettings(_subCallbacks.getReading(), _subCallbacks.getReporting(), _subCallbacks.getSubsInfo());
        if(_location) { storeSubcriptions(); }
    }
    
    // Updates reading/reporting interval settings with response from FB settings listener
    function _updateIntervals(path, res) {
        local node = split(path, "/").pop();
        local newSetting = {};
        if (res && node == "readingInterval") {
            newSetting.readingInterval <- res.tointeger();
            server.log("updating Reading Interval to "+res);
        }
        if (res && node == "reportingInterval") {
            newSetting.reportingInterval <- res.tointeger();
            server.log("updating Reporting Interval to "+res);
        }
        _updateLocalSettings(newSetting);
    }
    
    // Sets agent's reading/reporting interval to the settings passed in
    function _updateLocalSettings(newSettings) {
        if("readingInterval" in newSettings) { _subCallbacks.setReading(newSettings.readingInterval); }
        if("reportingInterval" in newSettings) { _subCallbacks.setReporting(newSettings.reportingInterval); }
    }
    
    // Opens Firebase listeners 
    function _openListeners() {
        _fb.stream("/settings", true);
        
        // listen for changes to reading and reporting intervals
        _fb.on("/devices/"+_agentID+"/readingInterval", _updateIntervals.bindenv(this));
        _fb.on("/devices/"+_agentID+"/reportingInterval", _updateIntervals.bindenv(this));
        
        // listen for changes to location
        _fb.on("/devices/"+_agentID+"/location", _updateLocation.bindenv(this));
    }

}
    
/////////////////////////////  Run Time  ///////////////////////////////

server.log("AGENT RUNNING");

const FIREBASENAME = "noraofficesensors";
const FIREBASESECRET = "Nvq5qcyxI5SI9ovPZQlMKpnRI2Q3zkg38BRj9DjV";

firebase <- Firebase(FIREBASENAME, FIREBASESECRET);
bullwinkle <- Bullwinkle();
sm <- SubscriptionManagerAgent(bullwinkle);

subCallbacks <- { "getReading" : sm.getReadingInterval.bindenv(sm),
                  "setReading" : sm.updateReadingInterval.bindenv(sm),
                  "getReporting" : sm.getReportingInterval.bindenv(sm),
                  "setReporting" : sm.updateReportingInterval.bindenv(sm),
                  "getSubsInfo" : sm.getSubscriptionsInfo.bindenv(sm),
                  "getActiveSubs" : sm.getActiveSubscriptions.bindenv(sm),
                  "getInactiveSubs" : sm.getInactiveSubscriptions.bindenv(sm),
                  "subscribe" : sm.subscribe.bindenv(sm),
                  "unsubscribe" : sm.unsubscribe.bindenv(sm) }

fb_mngr <- FBManager(firebase, subCallbacks);

// set callback for dataStreams
sm.updateBroadcastCallback (fb_mngr.storeReadings.bindenv(fb_mngr) );
