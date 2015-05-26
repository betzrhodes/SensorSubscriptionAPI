$(document).ready(function() {
    // Varaibles
    var roomNames = {maxwell: "Maxwell", hertz: "Hertz", faraday: "Faraday", gauss: "Gauss", watt: "Watt", balcrear: "Balcony Rear", ampere: "Ampere", volta: "Volta", reception: "Reception", lab: "Lab", kitchen: "Kitchen", balcfront: "Balcony Front", openofficearea: "Open Office Area", closet: "Closet"};
    var navTabs = ["dashboard", "channels", "settings"];
    var currentLocation = "Los_Altos";

    var tempGraphDataSets = [];
    var temp_graphData = [];

   // Graph Options
    var tempGraphOptions = {
        xaxis: {
            color: "#CCCCCC",
            mode: "time",
            tickLength: 1,
            ticks: 3,
            timeformat: "%I:%M %P",
            timezone: "browser",
        },
        yaxis: {tickFormatter: (function(val, axis) {return val + "°C"}),
                     position: "right",
                     min: 0,
                     max: 40,
                   },
        series: {
            lines: {
                show: true,
                lineWidth: 1.5,
                fill: 0.05
            },
            points: {
              show: true,
              fill: true,
              radius: 0.5
            },
        },
        grid: {
            backgroundColor: { colors: ["#7A7A7A", "#2B2B2B"] },
            hoverable: true,
            autoHighlight: true,
            margin: { right: 10, },
        },
        legend: {
          show: false,
          position: "nw",
          backgroundColor: "#7A7A7A",
          backgroundOpacity: 0.2,
          margin: 10
        },
        // colors: ["#004EF5", "#F6C600", "#DB0000"],
    };
    var tempHumidGraphOptions = {
      xaxis: {
          color: "#CCCCCC",
          mode: "time",
          tickLength: 1,
          ticks: 3,
          timeformat: "%I:%M %P",
          timezone: "browser",
      },
      yaxes: [ {tickFormatter: (function(val, axis) {return val + "°C"}),
                   position: "right",
                   min: 0,
                   max: 40,
                 },
                  {tickFormatter: (function(val, axis) {return val + "%"}),
                   position: "right",
                   min: 0,
                   max: 100,
                 },
                ],
      series: {
          lines: {
              show: true,
              lineWidth: 1.5,
              fill: 0.05
          },
          points: {
            show: true,
            fill: true,
            radius: 0.5
          },
      },
      grid: {
          backgroundColor: { colors: ["#7A7A7A", "#2B2B2B"] },
          hoverable: true,
          autoHighlight: true,
          margin: { right: 10, },
      },
      legend: {
        show: false,
        position: "nw",
        backgroundColor: "#7A7A7A",
        backgroundOpacity: 0.2,
        margin: 10
      },
      // colors: ["#004EF5", "#F6C600", "#DB0000"],
    };

    // Set up Image Map & Settings
    $('#ei-floorplan').mapster({
        render_highlight: {
          fillOpacity: 0.1,
        },
        render_select: {
          fillOpacity: 0.3,
        },
        fillColor: "95AD93",
        stroke: true,
        strokeColor: "206118",
        strokeOpacity: 0.8,
        strokeWidth: 1,
        singleSelect: true,
        isDeselectable: false,
        mapKey: 'name',
        listKey: 'name',
        onClick: function (e) {
            loadDashboard(e.key);
            return false;
        },
    });

    // Listeners
    $(".nav-sidebar li").on("click", function(e) {
      loadDashboard(e.currentTarget.dataset.roomName);
    })
    $(".navbar-right li").on("click", function(e) {
      updateNavBarActive(e.currentTarget)
      loadTab(e.currentTarget.dataset.navTab);
    });
    $(".container-fluid").on("click", ".sub-btn", updateChannelSettings);
      //form listeners
    $("#addDevice").on("click", submitAddForm);
    $("#configureDevice").on("click", submitConfigureForm);
    $("#deleteDevice").on("click", submitDeleteForm);
    $("#configure-agent-id ").on("change", fillConfigForm);

    function fbSettingsListener() {
      fb= new Firebase("impofficesensors.firebaseio.com/settings/");
      fb.on("child_changed", function(cs) {
        // loadTab( findActiveNavBar() );
        getAllDevices(syncSettingsAndLocations);
      });
    }

    /////////////// Run Time ////////////////
    loadTab( findActiveNavBar() );
    getAllDevices(syncSettingsAndLocations);
    fbSettingsListener(); //currently a catch all for all changes to settings

    ///////////// Page Navigation /////////////
    function loadTab(tab) {
      switch (tab) {
        case "dashboard" :
          loadDashboard( findActiveSidebar() );
          break;
        case "channels" :
          loadChannels();
          break;
        case "settings" :
          loadSettings();
          break;
      }
    }

    function loadDashboard(room) {
      showCurrentTab("dashboard");
      updateMap(room);
      updateSidebarList(room);
      updateDashboardRoomName(roomNames[room]);
      clearDashboard();
      getAllActiveSubscriptions(room, getDeviceInfo);
    }

    function loadChannels() {
      clearChannels();
      showCurrentTab("channels");
      getAllDevices(getSubscriptions);
    }

    function loadSettings() {
      showCurrentTab("settings");
      getActiveDevices(buildAgentIDDropdowns);
    }


    /////////////// Firebase Functions ///////////////////
    //uses location to get all active subscriptions for each agent from locations node
    function getAllActiveSubscriptions(location, callback) {
      fb = new Firebase("impofficesensors.firebaseio.com/locations/"+location+"/");
      fb.once("value", function(res) {
        if (res.val()) {
          for ( var agentID in res.val() ) {
            var activeSubscriptions = res.val()[agentID].active;
            if (activeSubscriptions) {
              if( callback ) { callback(agentID, checkSubscriptions, activeSubscriptions) };
            }
          }
        }
      })
    }

    //uses agentID to get device name & location from devices node
    function getDeviceInfo(agentID, callback, callbackParams) {
      var fb = new Firebase("impofficesensors.firebaseio.com/devices/"+agentID+"/");
      fb.once("value", function(res) {
        if (res.val()) {
          var deviceInfo = res.val();
          deviceInfo["agentID"] = agentID;
          callbackParams ? callback(callbackParams, deviceInfo) : callback(deviceInfo);
        }
      })
    }

    //gets all agentIDs from settings node
    function getAllDevices(callback, params) {
      $.ajax({
        url : "https://impofficesensors.firebaseio.com/settings.json?shallow=true",
        dataType : "jsonp",
        success : function(response) {
          var agentIDs = [];
          if (response != null){
            agentIDs = Object.keys(response);
          }
          params ? callback(agentIDs, params) : callback(agentIDs);
        }
      })
    }

    function getActiveDevices(callback){
      $.ajax({
        url : "https://impofficesensors.firebaseio.com/devices.json?shallow=true",
        dataType : "jsonp",
        success : function (response) {
          var agentIDs = [];
          if (response != null) {
            agentIDs = Object.keys(response);
          }
          callback(agentIDs);
        }
      })
    }

    //set up for subscription listeners in settings node
    function getSubscriptions(agentIDs) {
      var nodes = ["activeStreams", "inactiveStreams", "activeEvents", "inactiveEvents"];
      agentIDs.forEach(function(agentID) {
        nodes.forEach(function(node) {
          createFBSubscriptionReference(agentID, node, createSubscriptionButton);
        });
      });
    }

    //uses agentID and subscription node to create listeners in settings node
    function createFBSubscriptionReference(agentID, node, callback) {
      var fbRef = new Firebase("impofficesensors.firebaseio.com/settings/"+agentID+"/"+node+"/");
      fbRef.on("value", function(res) {
        if(res.val()) {
          for (var subscription in res.val()) {
            if (callback) { callback(agentID, node, subscription, res.val()[subscription].channelID) }
          }
        }
      })
    }

    //uses location agentID and subName to update subscription buttons from locations node
    function getSubscriptionInfo(subName, deviceInfo) {
      fbRef = new Firebase("impofficesensors.firebaseio.com/locations/"+deviceInfo.location+"/"+deviceInfo.agentID+"/available/"+subName+"/");
      fbRef.once("value", function(res) {
        if (res.val()) {
          updateSubButton(deviceInfo.agentID, ["name", subName], "h3", res.val().name);
          updateSubButton(deviceInfo.agentID, ["name", subName], ".area-desc", deviceInfo.name + " in " + roomNames[deviceInfo.location]);
          updateSubButtonDataAttr(subName, deviceInfo.location);
        }
      })
    }

    //uses agentID and channelID to get channel type from settings node
    function getChannelDesc(agentID, chanID, callback) {
      fbRef = new Firebase("impofficesensors.firebaseio.com/settings/"+agentID+"/channels/"+chanID+"/");
      fbRef.once("value", function(res) {
        if (res.val()) {
          callback(agentID, ["chan", chanID], ".chanID", "Sensor Type: " + res.val().type);
        }
      })
    }

    //uses agentID, subscription node and commandName to update subscription noded in settings
    function updateFBSettings(agentID, commandName, chanID, node) {
      fbSetting = new Firebase("impofficesensors.firebaseio.com/settings/"+agentID+"/"+node+"/"+commandName+"/");
      fbSetting.update({"channelID" : chanID});
    }

    //uses location, agentID, node and subscription to update the locations active node
    function updateFBLocations(location, agentID, node, commandName) {
      fbActive = new Firebase("impofficesensors.firebaseio.com/locations/"+location+"/"+agentID+"/active/");

      if (node.includes("inactive")) {
        fbAvail = new Firebase("impofficesensors.firebaseio.com/locations/"+location+"/"+agentID+"/available/");
        fbAvail.child(commandName).once("value", function(s) {
          fbActive.child(commandName).update(s.val());
        })
      } else {
        fbActive.child(commandName).remove();
      }
    }

    function openSettingsAvailListener(agentIDs) {
      var fb = new Firebase("impofficesensors.firebaseio.com/settings/");
      agentIDs.forEach(function(agentID) {
        fb.child(agentID+"/available/").on("child_changed", function(childSnapshot, prev) {
          if (childSnapshot.key()) {
            getDeviceInfo(agentID, updateLocationAvailable, childSnapshot.key());
          }
        })
        fb.child(agentID+"/available/").on("child_added", function(childSnapshot, prev) {
          if (childSnapshot.key()) {
            getDeviceInfo(agentID, updateLocationAvailable, childSnapshot.key());
          }
        })
        fb.child(agentID+"/available/").on("child_removed", function(oldChild) {
          if (oldChild.key()) {
            getDeviceInfo(agentID, deleteLocationAvailable, oldChild.key());
          }
        })
      })
    }

    function updateLocationAvailable(subscription, deviceInfo) {
      var fb = new Firebase("impofficesensors.firebaseio.com/locations/"+deviceInfo.location+"/"+deviceInfo.agentID+"/available/"+subscription+"/")
      fb.once("value", function(res) {
        if (!res.val()) {
          fb.update({ "name": deviceInfo.name+ " " +createName(subscription), "widget": "" });
        };
      })
    }

    function deleteLocationAvailable(subscription, deviceInfo) {
      var fb = new Firebase("impofficesensors.firebaseio.com/locations/"+deviceInfo.location+"/"+deviceInfo.agentID+"/available/"+subscription+"/")
      fb.once("value", function(res) {
        if (res.val()) { fb.remove() }
      })
    }

    function syncNodes(nodes, agentIDs) {
      var fb = new Firebase("impofficesensors.firebaseio.com/settings");

      agentIDs.forEach(function(agentID) {
        var subscriptions = [];
        nodes.forEach(function(node) {
          fb.child(agentID+"/"+node+"/").once("value", function(snapshot) {
            if (snapshot.val()) {
              subscriptions.push.apply(subscriptions, Object.keys(snapshot.val()));
            }
          })
        })
        if (nodes.length === 1) {
          getDeviceInfo(agentID, syncLocations, { "node" : "available", "subscriptions" : subscriptions});
        }
        if (nodes.length === 2) {
          getDeviceInfo(agentID, syncLocations, { "node" : "active", "subscriptions" : subscriptions});
        }
      })
    }

    function syncLocations(settingsData, deviceInfo) {
      var settingsSubs = settingsData.subscriptions
      var fb = new Firebase("impofficesensors.firebaseio.com/locations/"+deviceInfo.location+"/"+deviceInfo.agentID+"/");

      fb.child(settingsData.node).once("value", function(snapshot) {
        if(snapshot.val()) {
          var locSubs = Object.keys(snapshot.val());
          settingsData.subscriptions.forEach(function(sSub) {
            var match = false;
            locSubs.forEach(function(lSub) {
              if (sSub === lSub) {
                delete locSubs[locSubs.indexOf(lSub)];
                match = true;
              }
            })
            if (!match) {
              fb.child(settingsData.node+"/"+sSub).update({"name" :  deviceInfo.name+ " " +createName(sSub), "widget" : ""})
            }
          })
          locSubs = locSubs.filter(Boolean);
          if(locSubs.length > 0) {
            locSubs.forEach(function(sub){
              fb.child(settingsData.node+"/"+sub).remove();
            })
          }
        } else {
          settingsData.subscriptions.forEach(function(sub) {
            fb.child(settingsData.node+"/"+sub).update({"name" :  deviceInfo.name+ " " +createName(sub), "widget" : ""});
          })
        }
      })
    }

    function updateFBDeviceLocation(data, callback) {
      var fb = new Firebase("https://impofficesensors.firebaseio.com/devices/"+data.agentID+"/");
      fb.update( {"location": data.location, "name": data.name}, callback );
    };

    function deleteDevice(deviceInfo) {
      var fbDevices = new Firebase("https://impofficesensors.firebaseio.com/devices/"+deviceInfo.agentID);
      var fbLocations = new Firebase("https://impofficesensors.firebaseio.com/locations/"+deviceInfo.location+"/"+deviceInfo.agentID);
      fbDevices.remove();
      fbLocations.remove();
      updateDropdowns();
    }

    function getDeviceSubscriptionsInfo(agentID, location, callback) {
      var fb = new Firebase("https://impofficesensors.firebaseio.com/locations/"+location+"/"+agentID+"/available/");
      fb.once("value", function(snapshot) {
        callback(snapshot.val());
      })
    }

    /////////// View Functions /////////////////
    function createSubscriptionButton(agentID, node, subName, chanID) {
      if ($("[data-name="+subName+"][data-id="+agentID+"]").length > 0) { $("[data-name="+subName+"][data-id="+agentID+"]").remove() };
      $("."+node).append('<div data-id="'+agentID+'" data-name="'+subName+'" data-chan="'+chanID+'" class="sub-btn col-md-5"><h3></h3><p class="title-border"></p><p class="chanID"></p><p class="area-desc"></p></div>');
      getDeviceInfo(agentID, getSubscriptionInfo, subName);
      getChannelDesc(agentID, chanID, updateSubButton);
    }

    // attrArr = ["name", subName] or ["chan", chanID];
    // item = h3 or .chanID or .area-desc
    function updateSubButton(agentID, attrArr, item, text) {
      $("[data-id='"+agentID+"'][data-"+attrArr[0]+"='"+attrArr[1]+"'] "+item).text(text);
    }

    function updateSubButtonDataAttr(subName, location) {
      $("[data-name='"+subName+"']").attr("data-location", location);
    }


    function findActiveSidebar() {
      var room = $(".nav-sidebar .active").attr("data-room-name");
      // if (!room) {
      //   room = $(".nav-sidebar .active").parent().attr("data-room-name");
      // }
      return room
    }

    function findActiveNavBar() {
      return $(".navbar-right .active").attr("data-nav-tab")
    }

    function updateNavBarActive(tab) {
      $(".navbar-right .active").removeClass("active");
      tab.classList.add("active");
    }

    function clearDashboard() {
      $(".widgets").html('<div class="row-last"></div>');
    }

    function clearChannels() {
      $(".channels.tab").html('<h1 class="page-header">Channels</h1><div class="row"><div class="col-sm-6"><div data-node="activeStreams" class="activeStreams bkgnd"><h2>Active Streams</h2><p class="heading-border"></p></div></div><div class="col-sm-6"><div data-node="inactiveStreams" class="inactiveStreams bkgnd"><h2>Inactive Streams</h2><p class="heading-border"></p></div></div></div><div class="row"><div class="col-sm-6"><div data-node="activeEvents" class="activeEvents bkgnd"><h2>Active Events</h2><p class="heading-border"></p></div></div><div class="col-sm-6"><div data-node="inactiveEvents" class="inactiveEvents bkgnd"><h2>Inactive Events</h2><p class="heading-border"></p></div></div></div>');
    }

    function showCurrentTab(tab) {
      var index = navTabs.indexOf(tab);
      navTabs.splice(index, 1);
      $("."+tab+".tab").removeClass("hidden");
      for(var i = 0; i<navTabs.length; i++) {
        $("."+navTabs[i]+".tab").addClass("hidden");
      }
      navTabs.push(tab); //restore array
    }

    function updateSidebarList(room) {
      $(".nav-sidebar .active").removeClass("active");
      $("[data-room-name="+room+"]").addClass("active");
    }

    function updateMap(room) {
      $("area[name="+room+"]").mapster('set', true);
    }

    // Updates the page header with name of selected sidebar
    function updateDashboardRoomName(room) {
      $(".dashboard .page-header").text(room);
    }

    function createHumidGauge(canvasID, humidReading) {
      var canvas = document.getElementById(canvasID);
      var ctx = canvas.getContext("2d");
      var W = canvas.width;
      var H = canvas.height;
      ctx.clearRect(0, 0, W, H);

      ctx.beginPath();
      ctx.strokeStyle = '#E1E8DF';
      ctx.lineWidth = 40;
      ctx.arc(1/2*W, 6/7*H, 93, 1*Math.PI, 0*Math.PI, false);
      ctx.stroke();

      ctx.font = '40px Helvetica';
      var text_width = ctx.measureText(humidReading+"%").width;
      ctx.fillStyle = '#E1E8DF';
      ctx.fillText(humidReading+"%", W/2 - text_width/2, 3/4*H + 15);

      var endPoint = ( (humidReading / 100) * (Math.PI) ) + (Math.PI);
      ctx.beginPath();
      ctx.strokeStyle = "red";
      ctx.lineWidth = 40;
      ctx.arc(1/2*W, 6/7*H, 93, Math.PI, endPoint, false )
      ctx.stroke();
    }

    function createLightDot(canvasID, lightReading) {
      var canvas = document.getElementById(canvasID);
      var ctx = canvas.getContext("2d");
      var W = canvas.width;
      var H = canvas.height;
      ctx.clearRect(0, 0, W, H);

      ctx.font = '35px Helvetica';
      var text_width = ctx.measureText(lightReading+" LUX").width;
      ctx.fillStyle = '#E1E8DF';
      ctx.fillText(lightReading+" LUX", W/2 - text_width/2, 7/8*H + 15);

      // ctx.shadowColor = '#FEFFE6';
      // ctx.shadowOffsetX = 2;
      // ctx.shadowOffsetY = 1;
      // ctx.shadowBlur = 10;

      ctx.beginPath();
      ctx.arc(1/2*W, 1/3*H, 47, 0*Math.PI, 2*Math.PI, false);
      ctx.stroke();
      ctx.fillStyle = '#E3E3C5';
      ctx.fill();

    }

    function createDeviceWidget(deviceInfo, temp, humid, light) {
      if ($(".widgets [data-room-id='"+deviceInfo.agentID+"']").length > 0 ) {
        $(".widgets [data-room-id='"+deviceInfo.agentID+"']").html('<h3>'+deviceInfo.name+'</h3><p class="title-border"></p>'+temp+humid+light);
      } else {
        $(".widgets").prepend( '<div class="col-sm-7"><div class="room-widgets" data-room-id="'+deviceInfo.agentID+'"><h3>'+deviceInfo.name+'</h3><p class="title-border"></p>'+temp+humid+light+'</div></div> <!-- room-widgets -->' );
      }
    }

    function createLocalTempWidget() {
      if ($(".local-forcast").length > 0 ) { $(".local-forcast").remove() };
      $(".widgets .row-last").append('<div class="col-xs-6 col-sm-3 local-forcast right"><div class="widget" data-stream-name="weatherUnderground_localTemp"><p class="dash-heading1">Los Altos</p><p class="dash-heading2">Local Temperature</p><p class="heading-border"></p><div class"temp-box"><h2></h2></div><p class="text-muted time">updated @ 0:00:00 AM</p></div></div>');
    }

    function createTempHumidGraph(heading, agentID) {
      if ($("#"+agentID+"-temp-humid-graph").length > 0) {
          $("#"+agentID+"-temp-humid-graph").parent().parent().remove();
      }
      $(".widgets").prepend('<div class="col-xs-6 col-sm-5 right"><div class="temp-humid-graph"><h4>'+heading+'</h4><p class="title-border"></p><div class="sm-graph" id="'+agentID+'-temp-humid-graph"></div></div></div>');
    }

    function createTempGraph(location) {
      if ($("#"+location+"-temp-graph").length > 0) {
          $("#"+location+"-temp-graph").parent().parent().remove();
      }
      $(".widgets .row-last").append('<div class="col-xs-6 col-sm-9"><div class="temp-graph"><h4>'+roomNames[location]+' Temperature Graph</h4><p class="title-border"></p><div class="med-graph" id="'+location+'-temp-graph"></div></div></div>');
    }

    function buildLightWidgetHTMLString(subscription, agentID) {
      return '<div class="col-xs-6 col-sm-4 light"><div class="widget" data-stream-name="'+subscription+'"><p class="dash-heading1">Light</p><p class="heading-border"></p><canvas class="dot" id="light-'+agentID+'"></canvas><p class="text-muted time">updated @ 0:00:00 AM</p></div></div>'
    }

    function buildTempWidgetHTMLString(subscription) {
      return '<div class="col-xs-6 col-sm-4 temp"><div class="widget" data-stream-name="'+subscription+'"><p class="dash-heading1">Temperature</p><p class="heading-border"></p><div class="temp-box"><h2></h2></div><p class="text-muted time">updated @ 0:00:00 AM</p></div></div>'
    }

    function buildHumidWidgetHTMLString(subscription, agentID) {
      return '<div class="col-xs-6 col-sm-4 humidity"><div class="widget" data-stream-name="'+subscription+'"><p class="dash-heading1">Humidity</p><p class="heading-border"></p><canvas class="gauge" id="humid-'+agentID+'"></canvas><p class="text-muted time">updated @ 0:00:00 AM</p></div></div>'
    }

    function updateLightWidget(reading, time, agentID, stream) {
      updateTime(stream, time);
      createLightDot("light-"+agentID, reading);
    }

    function updateHumidWidget(reading, time, agentID, stream) {
      updateTime(stream, time);
      createHumidGauge("humid-"+agentID, Math.round(reading));
    }

    function updateTempWidget(reading, time, agentID, stream) {
      updateTime(stream, time);
      $(".temp-box h2").text(Math.round(reading)+"°C");
    }

    function updateTime(stream, time) {
      $("[data-stream-name='"+stream+"'] .time").text("updated @ "+time);
    }

    function updateGraph(id, data, options) {
      var plot = $.plot(id, data, options);
      plot.setupGrid();
      plot.draw();
    }

    function addGraphToolTip(id, graph, toolTipText) {
      if ($("#"+id+"-tooltip").length > 0) { $("#"+id+"-tooltip").remove() };
      $("<div id='"+id+"-tooltip' class='tooltip'></div>").appendTo("body");
      graph.bind("plothover", function (event, pos, item) {
        toolTipEvent(event, pos, item, id, toolTipText);
      })
    }

    function toolTipEvent(event, pos, item, id, toolTipText) {
      if (item) {
          var x = (new Date(item.datapoint[0])).toLocaleTimeString()
          var y = item.datapoint[1].toFixed(1);

          $("#"+id+"-tooltip").html("<p>" + item.series.label + "</p>" + x + "<br><span>" + y + toolTipText[item.seriesIndex] +"</span>")
            .css({top: item.pageY-50, left: item.pageX+5})
            .fadeIn(100);
      } else {
          $("#"+id+"-tooltip").hide();
      }
    }

    function buildAgentIDDropdowns(activeAgentIDs) {
      clearAgentIDDropdown();
      buildAgentIDDropdown($(".active-dev"), activeAgentIDs);
      getAllDevices(buildAddAIDDropdown, activeAgentIDs);
    }

    function buildAddAIDDropdown(allIDs, activeIDs) {
      activeIDs.forEach(function(id) {
        var i = allIDs.indexOf(id);
        allIDs.splice(i, 1);
      })
      buildAgentIDDropdown($("#add-agent-id"), allIDs);
    }

    function buildAgentIDDropdown(dropdown, agentIDs) {
      for (var i = 0; i < agentIDs.length; i++) {
        appendOption(dropdown, agentIDs[i]);
      }
    }

    function clearAgentIDDropdown() {
      $(".agent-id").html('<option selected="selected" disabled="disabled">Select a Device</option>');
    }

    function appendOption(dropdown, option) {
      dropdown.append('<option value="'+option+'">'+option+'</option>');
    }

    function buildSelectSubDropdown(subscriptions) {
      clearSelectSubDropdown();
      subscriptions.forEach(function(sub) {
        $(".sel-sub").append('<option value="'+sub+'">'+sub+'</option>');
      })
    }

    function clearSelectSubDropdown() {
      $(".sel-sub").html('<option selected="selected" disabled="disabled">Select a Subscription</option>');
    }

    function selectFormWidgets(widgets) {
      if ("light" in widgets) { $("#configure-widgets-light").val(widgets.light) };
      if ("temp" in widgets) { $("#configure-widgets-temp").val(widgets.temp) };
      if ("humid" in widgets) { $("#configure-widgets-humid").val(widgets.humid) };
    }

    function clearWidgetDropdowns() {
      $(".sel-sub").html('<option selected="selected" disabled="disabled">Select a Subscription</option>');
    }

    function addWidgetDropdownItem(subscription) {
        $(".sel-sub").append('<option value="'+subscription+'">'+subscription+'</option>');
    }

    function addConfigSubscriptionItem(name, subscription) {
      $(".subscriptions").append('<label class="sub-label" for="configure-'+subscription+'">'+subscription+': </label><input class="small-input" id="configure-'+subscription+'" type="text" value="'+name+'">');
    }


    ///////////////// Page Functionality /////////////////
    //match subscription widget in firebase to widget on dashboard
    function checkSubscriptions(activeSubscriptions, deviceInfo) {
      var fbLight, fbHumid, fbTemp, lightSub, tempSub, humidSub, tempIndex;
      var lightHTML = "";
      var humidHTML = "";
      var tempHTML = "";
      var tempHumid_graphData = [];

      for (var subscription in activeSubscriptions) {
        var fbRef = new Firebase("impofficesensors.firebaseio.com/data/"+deviceInfo.location+"/"+deviceInfo.agentID+"/"+subscription+"/");

        switch ( activeSubscriptions[subscription].widget ) {
          case "light" :
            fbLight = fbRef;
            lightSub = subscription;
            lightHTML = buildLightWidgetHTMLString(subscription, deviceInfo.agentID);
            break;
          case "temp" :
            fbTemp = fbRef;
            tempSub = subscription;
            tempHTML = buildTempWidgetHTMLString(subscription);
            //temp-humid graph setup
            tempHumid_graphData[0] = { label: activeSubscriptions[subscription].name, data: [], yaxis: 1 };
            //temp graph setup
            tempGraphDataSets.push(activeSubscriptions[subscription].name);
            tempIndex = tempGraphDataSets.indexOf(activeSubscriptions[subscription].name);
            temp_graphData[tempIndex] = { label: activeSubscriptions[subscription].name, data: [] };
            break;
          case "humid" :
            fbHumid = fbRef;
            humidSub = subscription
            humidHTML = buildHumidWidgetHTMLString(subscription, deviceInfo.agentID);
            //temp-humid graph setup
            tempHumid_graphData[1] = { label: activeSubscriptions[subscription].name, data: [], yaxis: 2 };
            break;
        }
      }

      if (tempHTML != "" || humidHTML != "" || lightHTML!= "") {
        //if any are blank make a different widget - adjust size of div style differently!!
        createDeviceWidget(deviceInfo, tempHTML, humidHTML, lightHTML);
      }

      if (fbTemp || fbHumid) {
        //create temp-humid graph & tooltip
        createTempHumidGraph(deviceInfo.name + " Temp/Humidity Graph", deviceInfo.agentID);
        addGraphToolTip(deviceInfo.agentID, $("#"+deviceInfo.agentID+"-temp-humid-graph"), [ "°C", "%" ]);
      }

      if (fbLight) {
        fbLight.limitToLast(1).on("child_added", function(cs, prev) {
          var time = new Date(cs.val().ts * 1000);
          updateLightWidget(cs.val().visible, time.toLocaleTimeString(), deviceInfo.agentID, lightSub);
        })
      }

      if (fbTemp) {
        //create temp graph & tooltip
        createTempGraph(deviceInfo.location);
        addGraphToolTip(deviceInfo.location, $("#"+deviceInfo.location+"-temp-graph"), [ "°C" ]);

        fbTemp.limitToLast(20).on("child_added", function(cs, prev) {
          var ts = cs.val().ts * 1000;
          var time = new Date(ts);
          var temp = cs.val().temp;
          //widget
          updateTempWidget(temp, time.toLocaleTimeString(), deviceInfo.agentID, tempSub);
          //temp-humid graph
          if( $("#"+deviceInfo.agentID+"-temp-humid-graph").length != 0 ) {
            tempHumid_graphData[0].data.push([ ts, temp ]);
            updateGraph( "#"+deviceInfo.agentID+"-temp-humid-graph", tempHumid_graphData, tempHumidGraphOptions);
          }
          //temp graph
          temp_graphData[tempIndex].data.push([ ts, temp ]);
          updateGraph( "#"+deviceInfo.location+"-temp-graph", temp_graphData, tempGraphOptions);
        })
      }

      if (fbHumid) {
        fbHumid.limitToLast(20).on("child_added", function(cs, prev) {
          var ts = cs.val().ts * 1000;
          var time = new Date(ts);
          var humid = cs.val().humid;
          //widget
          updateHumidWidget(humid, time.toLocaleTimeString(), deviceInfo.agentID, humidSub);
          //temp-humid graph
          if( $("#"+deviceInfo.agentID+"-temp-humid-graph").length != 0 ) {
            tempHumid_graphData[1].data.push([ ts, humid ]);
            if (!tempHumid_graphData[0]) {
              tempHumid_graphData[0] = { label: "", data: [], yaxis: 1 }
            }
            updateGraph("#"+deviceInfo.agentID+"-temp-humid-graph", tempHumid_graphData, tempHumidGraphOptions);
          }
        })
      }
      createLocalTempWidget();
      getLocalWeather();
      //get local temp data
      //add local temp data to temp graph
    }

    function updateChannelSettings(e) {
      e.stopPropagation();
      var agentID = e.currentTarget.dataset.id;
      var commandName = e.currentTarget.dataset.name;
      var chanID = e.currentTarget.dataset.chan;
      var node = e.currentTarget.parentElement.dataset.node;
      var oppositeNode = findOppositeNode(node);
      var location = e.currentTarget.dataset.location;

      updateFBSettings(agentID, commandName, chanID, oppositeNode);
      updateFBLocations(location, agentID, node, commandName)
    }

    function findOppositeNode(node) {
      switch (node) {
        case "activeStreams":
          return "inactiveStreams"
          break;
        case "inactiveStreams":
          return "activeStreams";
          break;
        case "activeEvents":
          return "inactiveEvents";
          break;
        case "inactiveEvents":
          return "activeEvents";
          break;
      }
    }

    function syncSettingsAndLocations(agentIDs) {
      syncNodes(["activeStreams", "activeEvents"], agentIDs);
      syncNodes(["available"], agentIDs);
      openSettingsAvailListener(agentIDs);
    }

    function createName(subscription) {
      var name = subscription.split("_").pop();
      name = name.split(/(?=[A-Z])/).join(" ");
      name = name[0].toUpperCase() + name.slice(1);
      return name;
    }

    function fillConfigForm(e) {
      agentID =  e.currentTarget.value;
      clearConfigDeviceForm();
      getDeviceInfo(agentID, function(res) {
        $("#configure-room-name").val(res.location);
        if (res.name != "") { $("#configure-device-name").val(res.name) };
        getDeviceSubscriptionsInfo(agentID, res.location, updateConfigFormInfo);
      })
      $(".dev-config").removeClass("hidden");
    }

    function updateConfigFormInfo(subscriptions) {
      var widgets = {};
      clearWidgetDropdowns();
      for (var subscription in subscriptions) {
        var widget = subscriptions[subscription].widget;
        addWidgetDropdownItem(subscription);
        addConfigSubscriptionItem(subscriptions[subscription].name, subscription);
        if (widget) {
          widgets[widget] = subscription;
        }
      }
      selectFormWidgets(widgets);
    }

    function updateDropdowns() {
      getActiveDevices(buildAgentIDDropdowns);
    }

    function clearConfigDeviceForm() {
      $("#configure-device .dev-info").html('<label for="configure-device-name">DEVICE NAME:</label><input id="configure-device-name" type="text" placeholder=" Device Name"><label>SUBSCRIPTION NAMES:</label><div class="sub-cat subscriptions"></div><label>WIDGETS:</label><div class="sub-cat"><label class="sub-label" for="configure-widgets-light">Light</label><select id="configure-widgets-light" class="dropdown small-input sel-sub" name="light-widget"><option selected="selected" disabled="disabled">Select a Subscription</option><option value="streamName">StreamName</option></select><label class="sub-label" for="configure-widgets-temp">Temperature</label><select id="configure-widgets-temp" class="dropdown small-input sel-sub" name="temp-widget"><option selected="selected" disabled="disabled">Select a Subscription</option><option value="streamName">StreamName</option></select><label class="sub-label" for="configure-widgets-humid">Humidity</label><select id="configure-widgets-humid" class="dropdown small-input sel-sub" name="humid-widget"><option selected="selected" disabled="disabled">Select a Subscription</option><option value="streamName">StreamName</option></select></div>');
    }


  ////////////////// Settings/Forms ///////////////////

    function submitAddForm(e) {
      var data = getAddDeviceInput();
      if ( data ) {
        getAllDevices(function(res) {
          if (res.indexOf(data.agentID) != -1) {
            updateFBDeviceLocation(data, function() {
              console.log ("device node updated");
              updateDropdowns();
            });
            syncSettingsAndLocations(res);
          }
        })
      } else {
        console.log("bad form input");
        //add user notification
      }
      $("#add-device").trigger("reset");
    }

    function submitConfigureForm(e) {
      var formData = getConfigureDeviceInput();
      updateFBDeviceLocation(formData);
      getActiveSubscriptions(formData.location, formData.agentID, updateFBLocationData, formData)
      $("#update-device").trigger("reset");
      updateDropdowns();
      $(".dev-config").addClass("hidden");
    }

    function updateFBLocationData(activeSubscriptions, formData) {
      var fb = new Firebase("https://impofficesensors.firebaseio.com/locations/"+formData.location+"/"+formData.agentID+"/");
      for (var sub in formData.subscriptions) {
        fb.child("available/"+sub).update({ "name" : formData.subscriptions[sub].name, "widget" : formData.subscriptions[sub].widget });
        if ( activeSubscriptions.indexOf(sub) != -1) {
          fb.child("active/"+sub).update({ "name" : formData.subscriptions[sub].name, "widget" : formData.subscriptions[sub].widget });
        }
      }
    }

    function getActiveSubscriptions(location, agentID, callback, params) {
      var fb = new Firebase("https://impofficesensors.firebaseio.com/locations/"+location+"/"+agentID+"/active/");
      fb.once("value", function(snapshot) {
        var activeSubs = Object.keys(snapshot.val());
        params ? callback(activeSubs, params) : callback(activeSubs);
      })
    }

    function getConfigureDeviceInput() {
      var agentID = $("#configure-agent-id").val();
      var location = $("#configure-room-name").val();
      var deviceName = $("#configure-device-name").val();
      var subscriptions = {};

      $(".subscriptions .small-input").each(function(i) {
        var id = $(this).attr('id');
        id = id.slice(10);
        subscriptions[id]= { "name" : $(this).val(), "widget" : "" };
      })

      var light = $("#configure-widgets-light").val();
      var temp = $("#configure-widgets-temp").val();
      var humid = $("#configure-widgets-humid").val();

      if (light) { subscriptions[light]["widget"] =  "light" };
      if (temp) { subscriptions[temp]["widget"] = "temp" };
      if (humid) { subscriptions[humid] ["widget"] = "humid" };

      return {"agentID": agentID, "location" : location, "name" : deviceName, "subscriptions" : subscriptions};
    };

    function submitDeleteForm(e) {
      var data = $("#delete-agent-id").val();
      if ( data ) {
        getDeviceInfo(data, deleteDevice)
      } else {
        console.log("bad form input");
      }
      $("#delete-temp-bug").trigger("reset");
    }

    function getAddDeviceInput() {
      var agentID = $("#add-agent-id").val();
      var location =  $("#add-room-name").val();
      var deviceName = $("#add-device-name").val();

      if(!deviceName) {deviceName = agentID};

      if (agentID.length === 12 && /^[a-z0-9_-]+$/i.test(agentID) && location) {
        return { "agentID" : agentID, "location" : location, "name" : deviceName };
      } else {
        return null;
      }
    };


///////////////// weather API & Helpers ///////////////////

  /* Gets current weather conditions for Los Altos from weather underground.
      Get Data on a loop, and May want to store in FB so can graph with other data.
  */

  function getLocalWeather() {
    // $.ajax({
    //   url : "http://api.wunderground.com/api/ab95457809980025/geolookup/conditions/q/CA/"+currentLocation+".json",
    //   dataType : "jsonp",
    //   success : function(parsed_json) {
    //     var location = parsed_json['location']['city'];
    //     var temp_c = parsed_json['current_observation']['temp_c'];
    //     $(".local-forcast .dash-heading1").text(location);
    //     $(".local-forcast h2").html((temp_c).toFixed() + "&deg C");
    //     var time = new Date();
    //     $(".local-forcast .time").text("updated @ " + time.toLocaleTimeString());
    //   }
    // });

    //dummy data to post so not hitting api when developping
    $(".local-forcast .dash-heading1").text("Los Altos");
    $(".local-forcast h2").html("18&deg C");
    var time = new Date();
    $(".local-forcast .time").text("updated @ " + time.toLocaleTimeString());
  };

  function getHistoricalWeatherData() {
    $.ajax({
      url : "http://api.wunderground.com/api/ab95457809980025/history_"+createTodaysDateString()+"/q/CA/"+currentLocation+".json",
      dataType : "jsonp",
      success : function(parsed_json) {
        // var location = "Los Altos";
        tempGraphDataSets.push("Local Forcast");
        var tempIndex = tempGraphDataSets.indexOf("Local Forcast");
        temp_graphData[tempIndex] = { label: "Local Forcast", data: [] };

        var history = parsed_json['history']['observations'];

        for(var i = 0; i < history.length; i++) {
          var d = history[i]['date'];
          var ts = Date.UTC( d.year, d.mon, d.mday, d.hour, d.min );
          var temp = history[i]['tempm'];

          temp_graphData[tempIndex].data.push([ ts, temp ]);
          // updateGraph( "#openofficearea-temp-graph", temp_graphData, tempGraphOptions);
        }
      }
    });
  }

  function createTodaysDateString() {
    var date = new Date();
    var month = date.getMonth() + 1;
    var day = date.getDate();
    var year = date.getFullYear();
    return year.toString() +month.toString() + day.toString();
  }

})
