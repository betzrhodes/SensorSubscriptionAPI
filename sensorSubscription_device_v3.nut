#require "Bullwinkle.class.nut:1.0.0"

#require "Si702x.class.nut:1.0.0"

// Ambient Light class
class SI1145 {

    _i2c    = null;
    _addr   = null;
    _alsInt  = null;
    _cb     = null;

    constructor(i2c, alsInt=null, addr=0xC0) {
        _i2c    = i2c;
        _alsInt = alsInt;
        _addr   = addr;
        if (_alsInt) {
            _alsInt.configure(DIGITAL_IN, interrupt.bindenv(this));
        }
        init();
    }

    // -------------------------------------------------------------------------
    function _read(reg, numBytes) {
        local result = _i2c.read(_addr, reg.tochar(), numBytes);
        if (result == null) {
            server.error("I2C read error: " + _i2c.readerror());
        }
        return result;
    }

    // -------------------------------------------------------------------------
    function _write(reg, ...) {
        local s = reg.tochar();
        foreach (b in vargv) {
            s += b.tochar();
        }
        local result = _i2c.write(_addr, s);
        if (result) {
            server.error("I2C write error: " + result);
        }
        return result;
    }

    function init() {

        enum SI1145_REG {
            PART_ID      = 0x00
            REV_ID       = 0x01
            SEQ_ID       = 0x02
            INT_CFG      = 0x03
            IRQ_ENABLE   = 0x04
            HW_KEY       = 0x07
            MEAS_RATE0   = 0x08
            MEAS_RATE1   = 0x09
            PS_RATE      = 0x0A
            PS_LED21     = 0x0F
            PS_LED3      = 0x10
            UCOEF0       = 0x13
            UCOEF1       = 0x14
            UCOEF2       = 0x15
            UCOEF3       = 0x16
            PARAM_WR     = 0x17
            COMMAND      = 0x18
            RESPONSE     = 0x20
            IRQ_STATUS   = 0x21
            ALS_VIS_DATA0= 0x22
            ALS_VIS_DATA1= 0x23
            ALS_IR_DATA0 = 0x24
            ALS_IR_DATA1 = 0x25
            PS1_DATA0    = 0x26
            PS1_DATA1    = 0x27
            PS2_DATA0    = 0x28
            PS2_DATA1    = 0x29
            PS3_DATA0    = 0x2A
            PS3_DATA1    = 0x2B
            AUX_DATA0    = 0x2C
            AUX_DATA1    = 0x2D
            PARAM_RD     = 0x2E
            CHIP_STAT    = 0x30
        }

        enum SI1145_CMD {
            PARAM_QUERY  = 0x80
            PARAM_SET    = 0xA0
            NOP          = 0x00
            RESET        = 0x01
            BUSADDR      = 0x02
            PS_FORCE     = 0x05
            GET_CAL      = 0x12
            ALS_FORCE    = 0x06
            PSALS_FORCE  = 0x07
            PS_PAUSE     = 0x09
            ALS_PAUSE    = 0x0A
            PSALS_PAUSE  = 0x0B
            PS_AUTO      = 0x0D
            ALS_AUTO     = 0x0E
            PSALS_AUTO   = 0x0F
        }

        // Must write 0x17 to HW_KEY for proper operation of SI114x (from datasheet)
        _write(SI1145_REG.HW_KEY, 0x17);
        // Enable ALS (visible + IR) channels
        // (Writes 00110000 to CHLIST)
        _write(SI1145_REG.PARAM_WR, 0x30);
        _write(SI1145_REG.COMMAND, SI1145_CMD.PARAM_SET | 0x01);
        // Enable ALS interrupt
        _write(SI1145_REG.INT_CFG, 0x01);
        _write(SI1145_REG.IRQ_ENABLE, 0x01);
        // Set PS1_LED current
        _write(SI1145_REG.PS_LED21, 0x08);
    }

    function interrupt() {
        if (!_alsInt.read()) {
            // Clear interrupts
            _write(SI1145_REG.IRQ_STATUS, 0xFF);
            // Read data
            local data = _read(SI1145_REG.ALS_VIS_DATA0, 4);
            local resVis = (data[1] << 8) | data[0];
            local resIR = (data[3] << 8) | data[2];
            // server.log(format("Visible: 0x%04X, IR: 0x%04X", resVis, resIR));
            if (_cb) {
                _cb({visible = resVis, ir = resIR});
                _cb = null;
            }
        }
    }

    function read(callback=null) {
        // Force a single ALS measurement
        _write(SI1145_REG.COMMAND, SI1145_CMD.ALS_FORCE);
        if (callback) {
            _cb = callback;
            imp.wakeup(5, interrupt.bindenv(this));
        }
    }

    function prox(callback=null) {
        _write(SI1145_REG.COMMAND, SI1145_CMD.PS_FORCE);
        if (callback) {
            _cb = callback;
            imp.wakeup(5, interrupt.bindenv(this));
        }
    }
}

// Connection Manager Class
class Connection {

    static CONNECTION_TIMEOUT = 30;
    static CHECK_TIMEOUT = 5;
    static MAX_LOGS = 100;
    
    connected = null;
    connecting = false;
    stayconnected = true;
    reason = null;
    callbacks = null;
    blinkup_timer = null;
    logs = null;
    
    // .........................................................................
    constructor(_do_connect = true) {
        callbacks = {};
        logs = [];
        server.setsendtimeoutpolicy(RETURN_ON_ERROR, WAIT_TIL_SENT, CONNECTION_TIMEOUT);
        connected = server.isconnected();
        imp.wakeup(CHECK_TIMEOUT, _check.bindenv(this));
        
        if (_do_connect && !connected) imp.wakeup(0, connect.bindenv(this));
        else if (connected) imp.wakeup(0, _reconnect.bindenv(this));
    }
    
    
    // .........................................................................
    function _check() {
        imp.wakeup(CHECK_TIMEOUT, _check.bindenv(this));
        if (!server.isconnected() && !connecting && stayconnected) {
            // We aren't connected or connecting, so we should try
            _disconnected(NOT_CONNECTED, true);
        }
    }
    

    // .........................................................................
    function _disconnected(_reason, _do_reconnect = false) {
        local fireevent = connected;
        connected = false;
        connecting = false;
        reason = _reason;
        if (fireevent && "disconnected" in callbacks) callbacks.disconnected();
        if (_do_reconnect) connect();
    }
    
    // .........................................................................
    function _reconnect(_state = null) {
        if (_state == SERVER_CONNECTED || _state == null) {
            connected = true;
            connecting = false;
            
            // Dump the logs
            while (logs.len() > 0) {
                local logo = logs[0];
                logs.remove(0);
                local d = date(logo.ts);
                local msg = format("%04d-%02d-%02d %02d:%02d:%02d UTC %s", d.year, d.month+1, d.day, d.hour, d.min, d.sec, logo.msg);
                if (logo.err) server.error(msg);
                else          server.log(msg);
            }
            
            if ("connected" in callbacks) callbacks.connected(SERVER_CONNECTED);
        } else {
            connected = false;
            connecting = false;
            connect();
        }
    }
    
    
    // .........................................................................
    function connect(withblinkup = true) {
        stayconnected = true;
        if (!connected && !connecting) {
            server.connect(_reconnect.bindenv(this), CONNECTION_TIMEOUT);
            connecting = true;
        }
        
        if (withblinkup) {
            // Enable BlinkUp for 60 seconds
            imp.enableblinkup(true);
            if (blinkup_timer) imp.cancelwakeup(blinkup_timer);
            blinkup_timer = imp.wakeup(60, function() {
                blinkup_timer = null;
                imp.enableblinkup(false);
            }.bindenv(this))
            
        }
    }
    
    // .........................................................................
    function disconnect() {
        stayconnected = false;
        server.disconnect();
        _disconnected(NOT_CONNECTED, false);
    }

    // .........................................................................
    function isconnected() {
        return connected == true;
    }

    // .........................................................................
    function ondisconnect(_disconnected = null) {
        if (_disconnected == null) delete callbacks["disconnected"];
        else callbacks["disconnected"] <- _disconnected;
    }

    // .........................................................................
    function onconnect(_connected = null) {
        if (_connected == null) delete callbacks["connected"];
        else callbacks["connected"] <- _connected;
    }

    // .........................................................................
    function log(msg, err=false) {
        if (server.isconnected()) server.log(msg);
        else logs.push({msg=msg, err=err, ts=time()})
        if (logs.len() > MAX_LOGS) logs.remove(0);
    }

    // .........................................................................
    function error(msg) {
        log(msg, true);
    }

}

// Class for handling a couple of the sensors on the nora
// This class should not be reused unless you have the exact same board & are using it for the same functionality
// This class is dependent on Si702x & SI1145 (the classes for the sensors on the board)
// This class has functions that 
    // Initialize sensors with default parameters
    // Take readings for sensors
class HardwareManager {

    // 8-bit left-justified I2C address for sensors on nora
    // Temp/Humid
    static Si702x_ADDR = 0x80;
    // Amb Light
    static Si1145_ADDR = 0xC0; 

    // Variables to store initialized sensors
    _tempHumid = null;
    _ambLight = null;
    
    _i2c = null;
    
    constructor() {
        _i2c = hardware.i2c89;
        // Confgure i2c clockspeed
        _i2c.configure(CLOCK_SPEED_400_KHZ);
    }
    
    
    // Initialize Sensors
    function initializeTempHumid() {
        if(!_tempHumid) { 
            _tempHumid = Si702x(_i2c, Si702x_ADDR); 
        }
    }
    
    function initializeAmbLight() {
        if(!_ambLight) { 
            _ambLight = SI1145(_i2c, hardware.pinD, Si1145_ADDR); 
        }
    }


    // Sensor Readings
    function getTempHumidReading(callback, name=null) {
        _tempHumid.read(function(response) {
            if("err" in response) {
                callback(response.err, null, name);
                return
            }
            local data = { "temp": response.temperature,
                           "humid": response.humidity,
                           "ts": time() };
            callback( null, data, name); 
        }.bindenv(this));
    }
    
    function getLightReading(callback, name=null) {
        // SI1145 sensor class doesn't handle errs yet
        _ambLight.read(function(response){
            response.ts <- time(); //add timestamp to response
            callback(null, response, name);
        }.bindenv(this));
    }
}


// Class for Streaming Sensor Data
// This class handles sleep, wakeup, & connection behaviors, 
//   as well as collecting and storing data between connections
// This class is dependent on bullwinkle class
// This class requires 2 parameters when initialized
    // 1st Parameter : instance of Bullwinkle
    // 2nd Parameter : a table of subscriptions with their settings & callbacks
// This class has functions that 
    // Set a reading interval (time between sensor readings in sec)
    // Set a reporting interval (time between connection to agent in sec)
    // Get reading interval
    // Get reporting interval
    // Getters for subscrtiptions (available, active, dataStream)
    // Update a subscription's settings/callbacks
class SubscriptionMangagerDevice {
    // Ammount of time in sec between readings
    static DEFAULT_READING_INTERVAL = 300;
    // Ammount of time in sec between connections
    static DEFAULT_REPORTING_INTERVAL = 900; 
    // Ammount of time in sec to wait for all readings to return data
    static DEFAULT_READINGS_TIMEOUT = 2; 
    // If you want device side settings to override stored settings change this to true
    static OVERRIDE_STORED_SETTINGS = false;  
    
    _connectionManager = null;
    _bullwinkle = null;
    _subscriptionFlag = null;
    _defaultSubscriptionSettings = null;
    _readingsCounter = null;
    _readingsTimeout = null;
    
    constructor(bullwinkle, subscriptions) {
        // _connectionManager = cm;
        _bullwinkle = bullwinkle;
        _defaultSubscriptionSettings = _parseSubSettings(subscriptions);
        _updateNVSettings({"callbacks" : _parseSubCallbacks(subscriptions)});  
        _readingsCounter = 0;
        _readingsTimeout = DEFAULT_READINGS_TIMEOUT;
        
        _determineWakeReason();
    }
    
    // Runs subscribeFunction for all active subscriptions
    function activateSubscriptions() {
        local subs = getActiveSubscrtiptions(); 
        if (subs.len() > 0) {
            foreach(sub in subs) {
                if(nv.callbacks.subscriptions[sub]["subscribeFunction"]) {
                    nv.callbacks.subscriptions[sub]["subscribeFunction"]();
                }
            }
            _subscriptionFlag = true;
        } else {
            _subscriptionFlag = false;
        } 
    }
    
    // Interval Getters
    function getReadingInterval() {
        return nv.settings.readingInterval;
    }
    
    function getReportingInterval() {
        return nv.settings.reportingInterval;
    }
    
    function getReadingsTimeout() {
        return _readingsTimeout;
    }
    
    // Subscription Getters
    function getAvailableSubscriptions() {
        local availSubs = [];
        foreach (sub, info in nv.settings.subscriptions) {
            availSubs.push(sub);
        }
        return availSubs;
    }
    
    function getActiveSubscrtiptions() {
        local activeSubs = [];
        foreach (sub, info in nv.settings.subscriptions) {
            if (nv.settings.subscriptions[sub]["subscribedTo"] == true) {
                activeSubs.push(sub);
            }
        }
        return activeSubs;
    }
    
    function getActiveDataStreams() {
        local activeSubs = [];
        foreach (sub, info in nv.settings.subscriptions) {
            if (nv.settings.subscriptions[sub]["type"] == "dataStream" && nv.settings.subscriptions[sub]["subscribedTo"] == true) {
                activeSubs.push(sub);
            }
        }
        return activeSubs;
    }
    
    // Interval/Timeout Setters
    function setReadingInterval(newInterval) {
        nv.settings.readingInterval = newInterval;
    }
    
    function setReportingInterval(newInterval) {
        nv.settings.reportingInterval = newInterval;
    }
    
    function setReadingsTimeout(newTimeout) {
        _readingsTimeout = newTimeout;
    }
    
    // Subscription Setters
    // Takes the name of the subscription and a table with the setting and/or callback to be updated 
    function updateSubscriptions(subscription, subscriptionInfo) {
        // if subscription doesn't exsist add it to nv.settings.subscriptions table
        if (!(subscription in nv.settings.subscriptions)) { nv.settings.subscriptions[subscription] <- {}; }
        
        if ("channel" in subscriptionInfo) { nv.settings.subscriptions[subscription]["channel"] <- subscriptionInfo.channel; }
        if ("type" in subscriptionInfo) { nv.settings.subscriptions[subscription]["type"] <- subscriptionInfo.type; }
        if ("subscribedTo" in subscriptionInfo) { nv.settings.subscriptions[subscription]["subscribedTo"] <-subscriptionInfo.subscribedTo; }
        
        if ("subscribeFunction" in subscriptionInfo) { nv.callbacks.subscriptions[subscription]["subscribeFunction"] <- subscriptionInfo.subscribeFunction; }
        if ("subscriptionCallback" in subscriptionInfo) { nv.callbacks.subscriptions[subscription]["subscriptionCallback"] <- subscriptionInfo.subscriptionCallback; }
    }
    
    
    ////////////////////////////// Private Functions /////////////////////////
    
    // Takes subscription table and returns table of subscriptions with their settings
    function _parseSubSettings(subscriptions) {
        local settings = {};
        foreach (sub, info in subscriptions) {
            settings[sub] <- subscriptions[sub]["settings"];
        }
        return settings;
    }
    
    // Takes subscription table and returns table of subscriptions with their callbacks 
    function _parseSubCallbacks(subscriptions) {
        local callbacks = {};
        foreach (sub, info in subscriptions) {
            callbacks[sub] <- subscriptions[sub]["callbacks"];
        }
        return callbacks;
    }
    
    // Checks wake reason and executes appropiate actions
    function _determineWakeReason() {
        switch(hardware.wakereason()) {
            case WAKEREASON_TIMER:
                server.log("WOKE UP B/C TIMER EXPIRED");
                _checkTimers();
                break;
            case WAKEREASON_PIN:
                server.log("WOKE UP B/C PIN HIGH");
                _checkTimers();
                break;
            default:
                server.log("WOKE UP B/C RESTARTED DEVICE, LOADED NEW CODE, ETC");
                if(OVERRIDE_STORED_SETTINGS) {
                    _sendDefaultSubscriptionSettings();
                } else {
                    _getSubscriptionSettings();
                }
        }
    }
    
    // Creates NV table if not in root
    function _configureNV() {
        local root = getroottable();
        if ( !("nv" in root) ) { root.nv <- {}; }
    }
    
    // Updates nv with settings from given table & activates sensors
    function _updateNVSettings(newSettings, callback=null) {
        _configureNV();
        if( !("settings" in nv) ) { nv.settings <- { "subscriptions" : {} }; }
        if( !("callbacks" in nv) ) { nv.callbacks <- { "subscriptions" : {} }; } 

        if("settings" in newSettings) { nv.settings.subscriptions <- newSettings.settings; }
        if("callbacks" in newSettings) { nv.callbacks.subscriptions <- newSettings.callbacks; }
        
        activateSubscriptions();
        
        // stores reporting interval & sets a timestamp for next connection
        if("reportingInterval" in newSettings) { 
            nv.settings.reportingInterval <- newSettings.reportingInterval; 
            nv.settings.nextReportingTS <- time() + newSettings.reportingInterval;
        }
        
        // stores reading interval & sets a timestamp for next wakeup
        if("readingInterval" in newSettings) { 
            nv.settings.readingInterval <- newSettings.readingInterval; 
            if(_subscriptionFlag) {
                nv.settings.nextReadingTS <- time() + newSettings.readingInterval;
            } else {
                nv.settings.nextReadingTS <- time() + newSettings.reportingInterval;
            }
        }
        
        if(callback) { callback(); }
    }
    
    // Checks if we should take readings, if not checks if we should connect
    function _checkTimers() {
        local now = time();
        if( nv.settings.nextReadingTS < now ) {
            nv.settings.nextReadingTS <- now + nv.settings.readingInterval;
            _takeReadings();
        } else {
            _checkReportingTimer();
        }
    }
    
    // Connects and sends readings or sleeps
    function _checkReportingTimer() {
        local now = time();
        if( nv.settings.nextReportingTS < now ) {
            nv.settings.nextReportingTS <- now + nv.settings.reportingInterval;
            _checkWakeTS(_sendReadings);
        } else {
            _checkWakeTS(_sleep, true);
        }
    }
    
    // Gets all active dataStream subsriptions, runs their subscribe callback, & stores data in nv
    function _takeReadings() {
        local subs = getActiveDataStreams(); 
        _readingsCounter = subs.len();
        
        if (_readingsCounter > 0) {
            // Take readings for all active subscriptions
            foreach(sub in subs) {
                if(nv.callbacks.subscriptions[sub]["subscriptionCallback"]) {
                    nv.callbacks.subscriptions[sub]["subscriptionCallback"](function(err, reading, subName) {
                        if(err) { server.log("READING FAILED: " + subName + " " + err); } //reading failed - decide how we want to handle
                        if(reading) { _storeData(subName, reading); }
                        _readingsCounter--;
                    }.bindenv(this), sub);
                }
            }
            // If we haven't gotten readings within set timeout then stop waiting
            imp.wakeup(_readingsTimeout, function() {
                _readingsCounter = 0;
            }.bindenv(this));
        } else {
            server.log("Not Subscribed to any Streams");
        }
        
        // Checks that all readings have returned
        _checkReadingsComplete();
    }
    
    // Loop that checks if all readings have returned
    // After readings collected checks if time to send readings
    function _checkReadingsComplete() {
        if(_readingsCounter == 0) { 
            _checkReportingTimer();
        } else {
            imp.wakeup( 0.2, _checkReadingsComplete.bindenv(this) );
        }
    }
    
    // Takes a subscription name & data and stores to nv.readings
    function _storeData(sub, reading) {
        // Make sure we have a node to store readings
        _configureNV();
        if ( !("readings" in nv) ) { nv.readings <- {}; }
        if ( !(sub in nv.readings) ) { nv.readings[sub] <- []; }
        
        // Store readings 
        nv.readings[sub].push(reading);
    }
    
    // Resets nv.readings to empty table
    function _clearNVReadings() {
        server.log("clearinging readings");
        if ("readings" in nv) { nv.readings <- {}; }
    }
    
    
    // Connection & Sleep Handlers
    
    // Shut down everything and go to sleep
    function _sleep(timer) {
        server.log("going to sleep for " + timer + " sec");
        if (server.isconnected()) {
            imp.onidle(function() { server.sleepfor(timer); });
        } else {
            imp.deepsleepfor(timer);
        }
    }
    
    // If no subscriptions adjusts TS for next wakeup
    function _checkWakeTS(callback, sleep=false) {
        if(!_subscriptionFlag) {
            nv.settings.nextReadingTS <- nv.settings.nextReportingTS;
        }
        // If callback passed in was _sleep, pass timer into callback
        if(sleep) {
            callback(nv.settings.nextReadingTS - time()) 
        } else {
            callback();
        }
    }
    
    // Agent Device Communication
    
    // Gets settings from agent
    // If agent has settings updates nv with agent's settings
    // If agent returns empty table send agent default subscription settings
    function _getSubscriptionSettings() {
        _bullwinkle.send("getSubscriptionSettings", null)
            .onreply(function(context) {
                if(context.reply.len() != 0) {
                    _updateNVSettings(context.reply, _takeReadings);
                } else {
                    _sendDefaultSubscriptionSettings();
                }
            }.bindenv(this))
    }
    
    // Sends agent default subscription settings
    function _sendDefaultSubscriptionSettings() {
        local settings = { "readingInterval": DEFAULT_READING_INTERVAL, 
                           "reportingInterval": DEFAULT_REPORTING_INTERVAL, 
                           "settings" : _defaultSubscriptionSettings }; 
        _bullwinkle.send("sendDefaultSubscriptionSettings", settings);
        _updateNVSettings(settings, _checkTimers);
    }
    
    // Send readings, if reply contains settings update nv with new settings
    function _sendReadings() {
        // _connectionManager.connect(); // check for connection??
        local data = null;
        if("readings" in nv) { data = nv.readings; }
        _bullwinkle.send("sendReadings", data)
            .onack(function(context) {
                _clearNVReadings();
            }.bindenv(this))
            .onreply(function(context) {
                if("settings" in context.reply) { 
                    server.log("updating settings");
                    _updateNVSettings(context.reply);
                    _bullwinkle.send("receivedSettings", null);
                }
                _sleep(nv.settings.nextReadingTS - time());
            }.bindenv(this));
    }
    
}


/////////////////////////////  Run Time  ///////////////////////////////

server.log("DEVICE RUNNING");

// cm <- Connection();
nora <- HardwareManager();
bullwinkle <- Bullwinkle();

// Subscription table 
    // Key: name or identifier
    // Value : table
        // sensor type / channels 
        // subscription type (event, dataStream)
        // currently subscribed (boolean)
        // subscribe setup function 
        // subscription callback function
subscriptions <- {  "tempHumidSensorTempHumid" : { "settings" : { "channel" : ["temp", "humid"], 
                                                                  "type" : "dataStream",
                                                                  "subscribedTo" : false },
                                                   "callbacks" : { "subscribeFunction" : nora.initializeTempHumid.bindenv(nora), 
                                                                   "subscriptionCallback" : nora.getTempHumidReading.bindenv(nora) }
                                                 },
                    "ambientLightSensorLight" : { "settings" : { "channel" : "light", 
                                                                 "type" : "dataStream",
                                                                 "subscribedTo" : false },
                                                  "callbacks" : { "subscribeFunction" : nora.initializeAmbLight.bindenv(nora), 
                                                                  "subscriptionCallback" : nora.getLightReading.bindenv(nora) }
                                                }
                  };
 
// must pass in bullwinkle and a subscription table even if table is empty          
subscribe <- SubscriptionMangagerDevice(bullwinkle, subscriptions);
