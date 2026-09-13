If you are using Rails, then you already has a `app/assets/javascripts/cable.js` file that requires `action_cable`,
you just need to connect to the right URL (don't forgot the settings you used). To authenticate using JWT, keep the
token out of the URL and offer it as a subprotocol entry with `addSubProtocol` (ActionCable 7.1 or newer), before
any subscription opens the connection:

  ```js
  (function() {
    this.App || (this.App = {});

    App.cable = ActionCable.createConsumer(
    "ws://localhost:5000/cable" // if using the default options
    );
    App.cable.addSubProtocol("cable-token." + JWT_TOKEN); // settings.token_subprotocol_prefix
  }.call(this));
  ```

  then on your `app/assets/javascripts/channels/chat.js`

  ```js
  App.channels || (App.channels = {});

  App.channels["chat"] = App.cable.subscriptions.create(
  {
    channel: "ChatChannel",
    room: "1"
  },
  {
    connected: function() {
      return console.log("ChatChannel connected");
    },
    disconnected: function() {
      return console.log("ChatChannel disconnected");
    },
    received: function(data) {
      return console.log("ChatChannel received", data);
    },
    rejected: function() {
      return console.log("ChatChannel rejected");
    },
    away: function() {
      return this.perform("away");
    },
    status: function(status) {
      return this.perform("status", {
        status: status
      });
    }
  }
  );
  ```

  Then on your Browser console you can see the message:

  > ChatChannel connected

  After you load, then you can broadcast messages with:

  ```js
  App.channels["chat"].send({ message: "Hello World" });
  ```

  And performs an action with:

  ```js
  App.channels["chat"].perform("status", { status: "My New Status" });
  ```
