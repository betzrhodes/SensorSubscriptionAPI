//helper printing function
function logTable(t, i = 0) {
    local indentString = "";
    for(local x = 0; x < i; x++) indentString += " ";

    foreach(k, v in t) {
        if (typeof(v) == "table" || typeof(v) == "array") {
            local par = "[]";
            if (typeof(v) == "table") par = "{}";

            server.log(indentString + k + ": " + par[0].tochar());
            logTable(v, i+4);
            server.log(par[1].tochar());
        }
        else {
            server.log(indentString + k + ": " + v);
        }
    }
}


/******************** Bullwinkle Setup ********************/
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

/******************** Sensor Tail Class ********************/
// Copyright (c) 2014 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT
class TMP1x2 {
    // Register addresses
    static TEMP_REG         = 0x00;
    static CONF_REG         = 0x01;
    static T_LOW_REG        = 0x02;
    static T_HIGH_REG       = 0x03;
    // Send this value on general-call address (0x00) to reset device
    static RESET_VAL        = 0x06;
    // ADC resolution in degrees C
    static DEG_PER_COUNT    = 0.0625;

    // i2c address
    _addr   = null;
    // i2c bus (passed into constructor)
    _i2c    = null;
    // interrupt pin (configurable)
    _intPin = null;
    // configuration register value
    _conf   = null;

    // Default temp thresholds
    _lowThreshold   = 75; // Celsius
    _highThreshold  = 80;

    // Default mode
    _extendedMode   = false;
    _shutdown       = false;

    // conversion ready flag
    _convReady      = false;

    // interrupt state - some pins require us to poll the interrupt pin
    _lastIntState       = null;
    _pollInterval       = null;
    _interruptCallback  = null;

    // generic temp interrupt
    function _defaultInterrupt(state) {
        server.log("Device: TMP1x2 Interrupt Occurred. State = "+state);
    }

    /*
     * Class Constructor. Takes 3 to 5 arguments:
     *      i2c:                    Pre-configured I2C Bus
     *      addr:                   I2C Slave Address for device. 8-bit address.
     *      intPin:                 Pin to which ALERT line is connected
     *      alertPollInterval:      Interval (in seconds) at which to poll the ALERT pin (optional)
     *      alertCallback:          Callback to call on ALERT pin state changes (optional)
     */
    constructor(i2c, addr, intPin, alertPollInterval = 1, alertCallback = null) {
        _addr   = addr;
        _i2c    = i2c;
        _intPin = intPin;

        /*
         * Top-level program should pass in Pre-configured I2C bus.
         * This is done to allow multiple devices to be constructed on the bus
         * without reconfiguring the bus with each instantiation and causing conflict.
         */
        _intPin.configure(DIGITAL_IN);
        _lastIntState = _intPin.read();
        _pollInterval = alertPollInterval;
        if (alertCallback) {
            _interruptCallback = alertCallback;
        } else {
            _interruptCallback = _defaultInterrupt;
        }
        readConf();
    }

    /*
     * Check for state changes on the ALERT pin.
     *
     * Not all imp pins allow state-change callbacks, so ALERT pin interrupts are implemented with polling
     *
     */
    function pollInterrupt() {
        imp.wakeup(_pollInterval, pollInterrupt.bindenv(this));
        local intState = _intPin.read();
        if (intState != _lastIntState) {
            _lastIntState = intState;
            _interruptCallback(state);
        }
    }

    /*
     * Take the 2's complement of a value
     *
     * Required for Temp Registers
     *
     * Input:
     *      value: number to take the 2's complement of
     *      mask:  mask to select which bits should be complemented
     *
     * Return:
     *      The 2's complement of the original value masked with the mask
     */
    function twosComp(value, mask) {
        value = ~(value & mask) + 1;
        return value & mask;
    }

    /*
     * General-call Reset.
     * Note that this may reset other devices on an i2c bus.
     *
     * Logging is included to prevent this from silently affecting other devices
     */
    function reset() {
        server.log("TMP1x2 Class issuing General-Call Reset on I2C Bus.");
        _i2c.write(0x00,format("%c",RESET_VAL));
        // update the configuration register
        readConf();
        // reset the thresholds
        _lowThreshold = 75;
        _highThreshold = 80;
    }

    /*
     * Read the TMP1x2 Configuration Register
     * This updates several class variables:
     *  - _extendedMode (determines if the device is in 13-bit extended mode)
     *  - _shutdown     (determines if the device is in low power shutdown mode / one-shot mode)
     *  - _convReady    (determines if the device is done with last conversion, if in one-shot mode)
     */
    function readConf() {
        _conf = _i2c.read(_addr,format("%c",CONF_REG), 2);
        // Extended Mode
        if (_conf[1] & 0x10) {
            _extendedMode = true;
        } else {
            _extendedMode = false;
        }
        if (_conf[0] & 0x01) {
            _shutdown = true;
        } else {
            _shutdown = false;
        }
        if (_conf[1] & 0x80) {
            _convReady = true;
        } else {
            _convReady = false;
        }
    }

    /*
     * Read, parse and log the current state of each field in the configuration register
     *
     */
    function printConf() {
        _conf = _i2c.read(_addr,format("%c",CONF_REG), 2);
        server.log(format("TMP1x2 Conf Reg at 0x%02x: %02x%02x",_addr,_conf[0],_conf[1]));

        // Extended Mode
        if (_conf[1] & 0x10) {
            server.log("TMP1x2 Extended Mode Enabled.");
        } else {
            server.log("TMP1x2 Extended Mode Disabled.");
        }

        // Shutdown Mode
        if (_conf[0] & 0x01) {
            server.log("TMP1x2 Shutdown Enabled.");
        }
        else {
            server.log("TMP1x2 Shutdown Disabled.");
        }

        // One-shot Bit (Only care in shutdown mode)
        if (_conf[0] & 0x80) {
            server.log("TMP1x2 One-shot Bit Set.");
        } else {
            server.log("TMP1x2 One-shot Bit Not Set.");
        }

        // Thermostat or Comparator Mode
        if (_conf[0] & 0x02) {
            server.log("TMP1x2 in Interrupt Mode.");
        } else {
            server.log("TMP1x2 in Comparator Mode.");
        }

        // Alert Polarity
        if (_conf[0] & 0x04) {
            server.log("TMP1x2 Alert Pin Polarity Active-High.");
        } else {
            server.log("TMP1x2 Alert Pin Polarity Active-Low.");
        }

        // Alert Pin
        if (_intPin.read()) {
            if (_conf[0] & 0x04) {
                server.log("TMP1x2 Alert Pin Asserted.");
            } else {
                server.log("TMP1x2 Alert Pin Not Asserted.");
            }
        } else {
            if (_conf[0] & 0x04) {
                server.log("TMP1x2 Alert Pin Not Asserted.");
            } else {
                server.log("TMP1x2 Alert Pin Asserted.");
            }
        }

        // Alert Bit
        if (_conf[1] & 0x20) {
            server.log("TMP1x2 Alert Bit  1");
        } else {
            server.log("TMP1x2 Alert Bit: 0");
        }

        // Conversion Rate
        local convRate = (_conf[1] & 0xC0) >> 6;
        switch (convRate) {
            case 0:
                server.log("TMP1x2 Conversion Rate Set to 0.25 Hz.");
                break;
            case 1:
                server.log("TMP1x2 Conversion Rate Set to 1 Hz.");
                break;
            case 2:
                server.log("TMP1x2 Conversion Rate Set to 4 Hz.");
                break;
            case 3:
                server.log("TMP1x2 Conversion Rate Set to 8 Hz.");
                break;
            default:
                server.error("TMP1x2 Conversion Rate Invalid: "+format("0x%02x",convRate));
        }

        // Fault Queue
        local faultQueue = (_conf[0] & 0x18) >> 3;
        server.log(format("TMP1x2 Fault Queue shows %d Consecutive Fault(s).", faultQueue));
    }

    /*
     * Enter or exit low-power shutdown mode
     * In shutdown mode, device does one-shot conversions
     *
     * Device comes up with shutdown disabled by default (in continuous-conversion/thermostat mode)
     *
     * Input:
     *      State (bool): true to enable shutdown/one-shot mode.
     */
    function shutdown(state) {
        readConf();
        local newConf = 0;
        if (state) {
            newConf = ((_conf[0] | 0x01) << 8) + _conf[1];
        } else {
            newConf = ((_conf[0] & 0xFE) << 8) + _conf[1];
        }
        _i2c.write(_addr, format("%c%c%c",CONF_REG,(newConf & 0xFF00) >> 8,(newConf & 0xFF)));
        // readConf() updates the variables for shutdown and extended modes
        readConf();
    }

    /*
     * Enter or exit 13-bit extended mode
     *
     * Input:
     *      State (bool): true to enable 13-bit extended mode
     */
    function setExtendedMode(state) {
        readConf();
        local newConf = 0;
        if (state) {
            newConf = ((_conf[0] << 8) + (_conf[1] | 0x10));
        } else {
            newConf = ((_conf[0] << 8) + (_conf[1] & 0xEF));
        }
        _i2c.write(_addr, format("%c%c%c",CONF_REG,(newConf & 0xFF00) >> 8,(newConf & 0xFF)));
        readConf();
    }

    /*
     * Set the T_low threshold register
     * This value is used to determine the state of the ALERT pin when the device is in thermostat mode
     *
     * Input:
     *      newLow: new threshold register value in degrees Celsius
     *
     */
    function setLowThreshold(newLow) {
        newLow = (newLow / DEG_PER_COUNT).tointeger();
        local mask = 0x0FFF;
        if (_extendedMode) {
            mask = 0x1FFF;
            if (newLow < 0) {
                twosComp(newLow, mask);
            }
            newLow = (newLow & mask) << 3;
        } else {
            if (newLow < 0) {
                twosComp(newLow, mask);
            }
            newLow = (newLow & mask) << 4;
        }
        server.log(format("setLowThreshold setting register to 0x%04x (%d)",newLow,newLow));
        _i2c.write(_addr, format("%c%c%c",T_LOW_REG,(newLow & 0xFF00) >> 8, (newLow & 0xFF)));
        _lowThreshold = newLow;
    }

    /*
     * Set the T_high threshold register
     * This value is used to determine the state of the ALERT pin when the device is in thermostat mode
     *
     * Input:
     *      newHigh: new threshold register value in degrees Celsius
     *
     */
    function setHighThreshold(newHigh) {
        newHigh = (newHigh / DEG_PER_COUNT).tointeger();
        local mask = 0x0FFF;
        if (_extendedMode) {
            mask = 0x1FFF;
            if (newHigh < 0) {
                twosComp(newHigh, mask);
            }
            newHigh = (newHigh & mask) << 3;
        } else {
            if (newHigh < 0) {
                twosComp(newHigh, mask);
            }
            newHigh = (newHigh & mask) << 4;
        }
        server.log(format("setHighThreshold setting register to 0x%04x (%d)",newHigh,newHigh));
        _i2c.write(_addr, format("%c%c%c",T_HIGH_REG,(newHigh & 0xFF00) >> 8, (newHigh & 0xFF)));
        _highThreshold = newHigh;
    }

    /*
     * Read the current value of the T_low threshold register
     *
     * Return: value of register in degrees Celsius
     */
    function getLowThreshold() {
        local result = _i2c.read(_addr, format("%c",T_LOW_REG), 2);
        local t_low = (result[0] << 8) + result[1];
        //server.log(format("getLowThreshold got: 0x%04x (%d)",t_low,t_low));
        local mask = 0x0FFF;
        local sign_mask = 0x0800;
        local offset = 4;
        if (_extendedMode) {
            //server.log("getLowThreshold: TMP1x2 in extended mode.")
            sign_mask = 0x1000;
            mask = 0x1FFF;
            offset = 3;
        }
        t_low = (t_low >> offset) & mask;
        if (t_low & sign_mask) {
            //server.log("getLowThreshold: Tlow is negative.");
            t_low = -1.0 * (twosComp(t_low,mask));
        }
        //server.log(format("getLowThreshold: raw value is 0x%04x (%d)",t_low,t_low));
        _lowThreshold = (t_low.tofloat() * DEG_PER_COUNT);
        return _lowThreshold;
    }

    /*
     * Read the current value of the T_high threshold register
     *
     * Return: value of register in degrees Celsius
     */
    function getHighThreshold() {
        local result = _i2c.read(_addr, format("%c",T_HIGH_REG), 2);
        local tHigh = (result[0] << 8) + result[1];
        local mask = 0x0FFF;
        local sign_mask = 0x0800;
        local offset = 4;
        if (_extendedMode) {
            sign_mask = 0x1000;
            mask = 0x1FFF;
            offset = 3;
        }
        tHigh = (tHigh >> offset) & mask;
        if (tHigh & sign_mask) {
            tHigh = -1.0 * (twosComp(tHigh,mask));
        }
        _highThreshold = (tHigh.tofloat() * DEG_PER_COUNT);
        return _highThreshold;
    }

    /*
     * If the TMP1x2 is in shutdown mode, write the one-shot bit in the configuration register
     * This starts a conversion.
     * Conversions are done in 26 ms (typ.)
     *
     */
    function startConversion() {
        readConf();
        local newConf = 0;
        newConf = ((_conf[0] | 0x80) << 8) + _conf[1];
        _i2c.write(_addr, format("%c%c%c",CONF_REG,(newConf & 0xFF00) >> 8,(newConf & 0xFF)));
    }

    /*
     * Read the temperature from the TMP1x2 Sensor
     *
     * Returns: current temperature in degrees Celsius
     */
    function readTempC() {
        if (_shutdown) {
            startConversion();
            _convReady = false;
            local timeout = 30; // timeout in milliseconds
            local start = hardware.millis();
            while (!_convReady) {
                readConf();
                if ((hardware.millis() - start) > timeout) {
                    server.error("Device: TMP1x2 Timed Out waiting for conversion.");
                    return -999;
                }
            }
        }
        local result = _i2c.read(_addr, format("%c", TEMP_REG), 2);
        local temp = (result[0] << 8) + result[1];

        local mask = 0x0FFF;
        local sign_mask = 0x0800;
        local offset = 4;
        if (_extendedMode) {
            mask = 0x1FFF;
            sign_mask = 0x1000;
            offset = 3;
        }

        temp = (temp >> offset) & mask;
        if (temp & sign_mask) {
            temp = -1.0 * (twosComp(temp, mask));
        }

        return temp * DEG_PER_COUNT;
    }

    /*
     * Read the temperature from the TMP1x2 Sensor and convert
     *
     * Returns: current temperature in degrees Fahrenheit
     */
    function readTempF() {
        local tempC = readTempC();
        if (tempC == -999) {
            return -999;
        } else {
            return (tempC * 9.0 / 5.0 + 32.0);
        }
    }
}

//magnitometer class (turns out we need this initialized for nora event wake up to work)
class LIS3MDL {
    _i2c    = null;
    _addr   = null;

    constructor(i2c, addr = 0x3C) {
        _i2c    = i2c;
        _addr   = addr;

        _init();
        getDeviceID();
    }

    function _init() {
        enum REG {
            WHO_AM_I    = 0x0F
            CTRL_REG1   = 0x20
            CTRL_REG2   = 0x21
            CTRL_REG3   = 0x22
            CTRL_REG4   = 0x23
            CTRL_REG5   = 0x24
            STATUS_REG  = 0x27
            OUT_X_L     = 0x28
            OUT_X_H     = 0x29
            OUT_Y_L     = 0x2A
            OUT_Y_H     = 0x2B
            OUT_Z_L     = 0x2C
            OUT_Z_H     = 0x2D
            INT_CFG     = 0x30
            INT_SRC     = 0x31
            INT_THS_L   = 0x32
            INT_THS_H   = 0x33
        }
        // Must enable interrupt pin for it to de-assert itself...
        _i2c.write(_addr, format("%c%c", REG.INT_CFG, 0x01));
    }

    function getDeviceID() {
        local id = _i2c.read(_addr, format("%c", REG.WHO_AM_I), 1);
        if (id) {
            if (id[0] != 0x3D) {
                server.log("Device returned invalid ID");
            }
        } else {
            server.log("error getting device ID: " + _i2c.readerror());
        }
    }

    function disable() {

        // _i2c.write(_addr, format("%c%c", REG.CTRL_REG2, 0x0C));
        // _i2c.write(_addr, format("%c%c", REG.CTRL_REG3, 0x00));
    }

    function printInterrupts() {
        local data = _i2c.read(_addr, REG.INT_SRC.tochar(), 1);
        server.log(format("0x%02X", data[0]));
    }

    function startRead() {
        // Enable magnetometer and take a single reading
        _i2c.write(_addr, format("%c%c", REG.CTRL_REG3, 0x01));
        _i2c.write(_addr, format("%c%c", REG.CTRL_REG1, 0x71));
        imp.wakeup(2, read.bindenv(this));
    }

    function read() {
        local data = _i2c.read(_addr, format("%c", REG.OUT_X_L), 6);
        if (data) {
            local x = (data[1] << 8) | data[0];
            local y = (data[3] << 8) | data[2];
            local z = (data[5] << 8) | data[4];
            server.log(format("x=%i, y=%i, z=%i", twos(x), twos(y), twos(z)));
        } else {
            server.log("received null reply");
            return null;
        }
    }
}

/******************** Sensor Setup ********************/
//when we initialize our sensor this is the variable we will store it in
noraTemp <- null;

//hardware config for temp sensor on nora
// 8-bit left-justified I2C address (Just an example.)
const TMP1x2_ADDR = 0x92;

//need to configure all sensor pins even if sensor is not active
hardware.pinA.configure(DIGITAL_IN);
hardware.pinB.configure(DIGITAL_IN);
hardware.pinC.configure(DIGITAL_IN);
hardware.pinD.configure(DIGITAL_IN);
hardware.pinE.configure(DIGITAL_IN);
// Alert pin
hardware.pin1.configure(DIGITAL_IN_WAKEUP);

//i2c setup
i2c         <- hardware.i2c89;
i2c.configure(CLOCK_SPEED_400_KHZ);

mag <- LIS3MDL(i2c); //needs to be initialized for event wakeup to function on nora??

//helper initialize function
function initializeTemp() {
    if (!noraTemp) { noraTemp <- TMP1x2(i2c, TMP1x2_ADDR, hardware.pinE); }
}

//uses parameters passed from agent to configure sensor
function setUpTempThermostat(params) {
    initializeTemp();
    if("low" in params) {noraTemp.setLowThreshold(params.low)};
    if("high" in params) {noraTemp.setHighThreshold(params.high)};
}

//table of sensor setup functions
//keys are the stream name/command - need to be the same as the agent side - "addSensorToSettings"
//values are the function to be run when we subscribe to stream/event
sensorSubscriptionFunctionsByCommand <- { "nora_tempReadings" : function() { initializeTemp(); return noraTemp.readTempC() },
                                          "nora_tempThermostat" : function(params) { setUpTempThermostat(params); },
                                        }

//this should clear all events - need this if we want the ability to unsubscribe from an event
//currently this is not working!
function resetEvents() {
    if(noraTemp) { noraTemp.reset(); }
}


/******************** Agent Communications ********************/
class deviceSideSensorAPI {
    //table to store info if event triggered a wakeup
     _eventTracker = { "triggered" : false,
                       "events" : [] };
    //table that stores event specific info - pin, polarity, callback
    _eventConfig = {};
    _bullwinkle = null;
    _commands = null;
    _clearEventsFunction = null;
    settings = null;
    data = null;

    //_name is the the namespace used to store data in the nv table, commands is the table of sensor functions, bullwinkle is instance of bullwinkle
    constructor(_name, commands, bullwinkle, clearEvents=null) {
        settings = _name + "Settings";
        data = _name + "Data";
        _commands = commands;
        _bullwinkle = bullwinkle;
        if (clearEvents) { _clearEventsFunction = clearEvents };
        init();
    }

    function init() {
        if(hardware.wakereason() == WAKEREASON_TIMER) {
            server.log("WOKE UP B/C TIMER EXPIRED")
            triggerTimerWakeUp();
        } else if(hardware.wakereason() == WAKEREASON_PIN) {
            //this will be empty for the first few ms after any wakeup that erases nv
            foreach(pin, reading in nv.eventPins) {
                nv.eventPins[pin] = hardware[pin].read();
            }
            server.log("WOKE UP B/C PIN HIGH");
            _eventTracker.triggered = true;
            //need to wait for event setup code to run - look for a better way to do this??
            imp.wakeup(0.001, function() {
                triggerEvent();
                sendEventData();
            }.bindenv(this))
        } else {
            server.log("WOKE UP B/C RESTARTED DEVICE, LOADED NEW CODE, ETC")
            getSettings();
        }
    }

    function setUpEvent(eventCommand, wakePin, eventTriggerPolarity, callback) {
        if(!(eventCommand in _eventConfig)) {_eventConfig[eventCommand] <- {}};
        _eventConfig[eventCommand] <- { "pin" : wakePin,
                                        "eventPolarity" : eventTriggerPolarity,
                                        "callback" : callback };
        local root = getroottable();
        if(!("nv" in root)) { root.nv <- {} };
        if(!("eventPins" in nv)) { nv["eventPins"] <- {}; };
        if(!(wakePin in nv.eventPins)) { nv.eventPins[wakePin] <- null};
    }

    function triggerEvent() {
        foreach(event, settings in _eventConfig) {
            foreach(pin, reading in nv.eventPins) {
                if(pin == settings.pin && reading == settings.eventPolarity) {
                    nv[data]["sensorReadings"][event].push(settings.callback());
                    _eventTracker.events.push(event);
                }
            }
        }
    }

    function sendEventData() {
        local d = {};
        foreach(event in _eventTracker.events) {
            d[event] <- nv[data]["sensorReadings"][event];
        }
        sendData(d);
    }

    function configureSettings(newSettings) {
        server.log("configuring new settings")
        configureNVTable(newSettings);
        if("activeStreams" in nv[settings]["subscriptions"]) { configureStreams(); }
        if("activeEvents" in nv[settings]["subscriptions"]) { configureEvents(); }
        agentComSuccessful();
    }

    //stores settings in NV, and sets up data storage for subscriptions
    function configureNVTable (newSettings) {
        local root = getroottable();
        if ( !("nv" in root) ) { root.nv <- {} };
        nv[settings] <- newSettings;
        nv[data] <- { "nextConnection" : time() + nv[settings]["reportingInterval"],
                      "nextWakeUp" : time() + nv[settings]["readingInterval"],
                      "sensorReadings" : {} };
    }

    //sets up data storage and next reading/wake/connection timestamps for streams
    function configureStreams() {
        foreach(stream in nv[settings]["subscriptions"]["activeStreams"]) {
            if(!(stream in nv[data]["sensorReadings"])) { nv[data]["sensorReadings"][stream] <- [] };
            takeReading(stream);
        }
    }

    //sets up data storage for events
    function configureEvents() {
        clearEvents();
        foreach(event, params in nv[settings]["subscriptions"]["activeEvents"]) {
            if(!(event in nv[data]["sensorReadings"])) { nv[data]["sensorReadings"][event] <- [] };
            send(event, params);
        }
    }

    function clearReadingData() {
        foreach(subscription, readings in nv[data]["sensorReadings"]) {
            nv[data]["sensorReadings"][subscription] = [];
        }
    }

    function takeReading(stream) {
        on(stream, function(resp) {
            server.log("reading " + resp)
            if(resp) {
                nv[data]["sensorReadings"][stream].push(resp);
            }
        });
    }

    function clearEvents() {
        _clearEventsFunction();
    }

    function on(command, callback) {
        if (command in _commands) {
            callback(_commands[command]());
        }
    }

    function send(command, data) {
        if (command in _commands) {
            _commands[command](data);
        }
    }

    function clearEventData() {
        foreach(event in _eventTracker.events) {
            nv[data]["sensorReadings"][event] = [];
        }
    }

    function resetEventTracker() {
        _eventTracker = { "triggered" : false,
                         "events" : [] }
    }

    function checkReportingInterval() {
        if (nv[data]["nextConnection"] <= time()) {
            local d = {};
            if ("sensorReadings" in nv[data] && nv[data]["sensorReadings"].len() > 0) {
                foreach(sensor, readings in nv[data]["sensorReadings"]) {
                    if(readings.len() > 0) { d[sensor] <- readings };
                }
            }
            sendData(d);
        } else {
            sleep(determineNextWake());
        }
    }

    function triggerTimerWakeUp() {
        nv[data]["nextWakeUp"] = nv[settings]["readingInterval"] + time();
        if("activeStreams" in nv[settings]["subscriptions"]) {
            foreach(stream in nv[settings]["subscriptions"]["activeStreams"]) {
                takeReading(stream);
            }
        }
        checkReportingInterval(); //sends data &/or sleeps
    }

    function determineNextWake() {
        if( "activeStreams" in nv[settings]["subscriptions"] && nv[settings]["subscriptions"]["activeStreams"].len() > 0) {
            return nv[settings]["readingInterval"];
        } else {
            return nv[settings]["reportingInterval"];
        }
    }

    function sleep(timer) {
        // Shut down everything and go back to sleep
        server.log("going to sleep for " + timer + " sec")
        if (server.isconnected()) {
            imp.onidle(function() {
                server.sleepfor(timer);
            })
        } else {
            imp.deepsleepfor(timer);
        }
    }

    function getSettings() {
        _bullwinkle.send("getSettings", null)
            .onreply(function(context) { configureSettings(context.reply); }.bindenv(this))
            .ontimeout(function(context) {
                server.log("Received reply from command '" + context.command + "' after " + context.latency + "s");
            })
            .onexception(function(context) {
                server.log("Received exception from command '" + context.command + ": " + context.exception);
            })
    }

    function sendData(d) {
        if(d.len() == 0) { d = null}
        _bullwinkle.send("sendData", d)
            .onreply(function(context) {
                if (context.reply) {
                    configureSettings(context.reply);
                } else {
                    if(_eventTracker.triggered) {
                        clearEventData();
                        resetEventTracker();
                        //this is not always the desired behavior for all sensors?? - thermostat for example
                        local wakeUpTimer = nv[data]["nextWakeUp"] - time();
                        wakeUpTimer > 0 ? sleep(wakeUpTimer) : triggerTimerWakeUp();
                    } else {
                        nv[data]["nextWakeUp"] = nv[settings]["readingInterval"] + time();
                        nv[data]["nextConnection"] = nv[settings]["reportingInterval"] + time();
                        if("sensorReadings" in nv[data]) { clearReadingData() };
                        sleep(determineNextWake());
                    }
                }
            }.bindenv(this))
            .ontimeout(function(context) {
                server.log("Received reply from command '" + context.command + "' after " + context.latency + "s");
            })
            .onexception(function(context) {
                server.log("Received exception from command '" + context.command + ": " + context.exception);
            })
    }

    function agentComSuccessful() {
        _bullwinkle.send("ack", null)
            .onreply(function(context) {
                sleep(determineNextWake());
            }.bindenv(this))
            .ontimeout(function(context) {
                server.log("Received reply from command '" + context.command + "' after " + context.latency + "s");
            })
            .onexception(function(context) {
                server.log("Received exception from command '" + context.command + ": " + context.exception);
            })
    }
}



//initialize our sensor communications layer
//params - name we want to use to store our data and settings under, our table of sensor setup functions,
//          our bullwinkle instance, our event reset function(optional - don't need if we don't have events)
api <- deviceSideSensorAPI("nora", sensorSubscriptionFunctionsByCommand, bullwinkle, resetEvents);

//if we have events we need to set up what happens when it is triggered
//params - event/stream name(same as agent and subscription command), interrupt pin,
//          polarity of pin when event triggerd,
//          function to exicute when event triggers - should return message or data to send to the agent/user
api.setUpEvent("nora_tempThermostat", "pinE", 0, function(){ initializeTemp(); return noraTemp.readTempC(); });



//data structure examples

/*nv:   { envSensorTailData: {  "nextWakeUp": 1422306809,
                                "nextConnection": 1422306864,
                                "sensorReadings": { "sensorTail_tempReadings" : [ readings... ],
                                                    "sensorTail_themostat" : [ readings... ] },
                              },
          envSensorTailSettings: {  readingInterval: 5,
                                    reportingInterval: 60,
                                    subscriptions: {
                                        "activeStreams" : [ "sensorTail_tempReadings",
                                                            "sensorTail_humidReadings" ],
                                        "activeEvents" : { "sensorTail_themostat" : {low: 20, high: 30} }
                                    }
                                 },
          eventPins: {"pinE":null, "pinA": null},
        }
*/

/*sensorSettings <- { "agentID" : agentID,
                    "reportingInterval" : reportingInterval,
                    "minReadingInterval" : minReadingInterval
                    "sensors" : [{ "sensorID" : 0,
                                   "type" : "temperature",  //type of sensor
                                   "active" : false,        //whether sensor is transmitting data/listening for event
                                   "availableStreams" : ["sensorTail_tempReadings", "sensorTail_humidReadings"],
                                   "availableEvents" : {},
                                   "activeStreams" : [],
                                   "activeEvents" : {} },
                                 { "sensorID" : 1,
                                  "type" : "humidity",
                                  "active" : false,
                                  "availableStreams" : ["sensorTail_humidReadings"],
                                  "availableEvents" : {},
                                  "activeStreams" : [],
                                  "activeEvents" : {} }]
                  };
*/


/* _eventConfig <- { "noraTemp_thermostat" : {"pin" : "pinE", "eventTriggerPolarity" : 0, "callback" : function(){ initializeTemp(); return noraTemp.readTempC();} },
                     "nora_baro" : {"pin" : "pinA", "eventTriggerPolarity" : 1, "callback" : function(){server.log("barometer event")} },
                     "nora_accel" : {"pin" : "pinB", "eventTriggerPolarity" : 1, "callback" : function(){server.log("accel event")} },
                     "nora_mag" : {"pin" : "pinC", "eventTriggerPolarity" : 0, "callback" : function(){server.log("mag event")} },
                     "nora_als" : {"pin" : "pinD", "eventTriggerPolarity" : 0, "callback" : function(){server.log("als event")} },
                    }
*/