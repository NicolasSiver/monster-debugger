package com.demonsters.debugger.netgroup
{
	import com.demonsters.debugger.IMonsterDebuggerClient;
	import com.demonsters.debugger.MonsterDebuggerConstants;
	import com.demonsters.debugger.MonsterDebuggerData;
	import flash.events.Event;
	import flash.events.IOErrorEvent;
	import flash.events.NetStatusEvent;
	import flash.events.ProgressEvent;
	import flash.events.SecurityErrorEvent;
	import flash.net.NetGroup;
	import flash.net.Socket;
	import flash.utils.ByteArray;


	public final class NetgroupClient implements IMonsterDebuggerClient
	{

		
		// Properties
		private var _id:String;
		private var _socket:Socket;
		private var _group:NetGroup;
		private var _bytes:ByteArray;
		private var _package:ByteArray;
		private var _length:uint;
		
		
		// The information
		private var _playerType:String;
		private var _playerVersion:String;
		private var _isDebugger:Boolean;
		private var _isFlex:Boolean;
		private var _fileTitle:String;
		private var _fileLocation:String;
		private var _isAnotherDebugger:Boolean;


		/**
		 * Getters for basic info
		 */
		public function get playerType():String {
			return _playerType;
		}
		public function get playerVersion():String {
			return _playerVersion;
		}
		public function get isDebugger():Boolean {
			return _isDebugger;
		}
		public function get isFlex():Boolean {
			return _isFlex;
		}
		public function get fileTitle():String {
			return _fileTitle;
		}
		public function get fileLocation():String {
			return _fileLocation;
		}


		// Callback functions
		// Format: onData(data:MonsterDebuggerData):void;
		// Format: onStart(target:MonsterDebuggerClient):void;
		// Format: onDisconnect(target:MonsterDebuggerClient):void;
		private var _onData:Function;
		private var _onStart:Function;
		private var _onDisconnect:Function;

		public function get onData():Function {
			return _onData;
		}
		public function get onStart():Function {
			return _onStart;
		}
		public function get onDisconnect():Function {
			return _onDisconnect;
		}
		public function set onData(value:Function):void {
			_onData = value;
		}
		public function set onStart(value:Function):void {
			_onStart = value;
		}
		public function set onDisconnect(value:Function):void {
			_onDisconnect = value;
		}
		
		
		/**
		 * Wrapper for socket
		 */
		public function NetgroupClient(group:NetGroup, id:String)
		{
			// Save id
			_group = group;
			_id = id;

			// Save socket and bytes
			_bytes = new ByteArray();
			_package = new ByteArray();
			_length = 0;
			_isAnotherDebugger = false;

			// Configure listeners
			if (_group != null) {
				_group.addEventListener(NetStatusEvent.NET_STATUS, onGroupUpdates, false, 0, true);
			}

			// Get the basic info needed to open a tab
			send(MonsterDebuggerConstants.ID, {command:MonsterDebuggerConstants.COMMAND_HELLO});
		}


		/**
		 * Called whenever something happens in the group we've joined on the peer-to-peer
		 * group. Other neighbors messages are being evaluated and we send out our own
		 * address as soon as we join successfully.
		 */
		private function onGroupUpdates(event:NetStatusEvent):void
		{
			switch (event.info.code) {
				case "NetGroup.Neighbor.Disconnect":
					if (event.info.neighbor == _id) {
						_group.removeEventListener(NetStatusEvent.NET_STATUS, onGroupUpdates);
						_group = null;
						_id = null;
						if (_onDisconnect != null) _onDisconnect(this);
						_onData = null;
						_onStart = null;
						_onDisconnect = null;
					}
					break;
				case "NetGroup.SendTo.Notify":
					if (event.info.from == _id) {
						var item:MonsterDebuggerData = new MonsterDebuggerData(event.info.message.id, event.info.message.data);
						if (item.id != null) {
							processData(item);
						}
					}
					break;
			}
		}


		/**
		 * Send data to the client
		 * @param id: The plugin id
		 * @param data: The data to send
		 */
		public function send(id:String, data:Object):void
		{
			// Use group mode
			if (_group != null) {
				
				// Get the data
				var obj:Object = {};
				obj["id"] = id;
				obj["data"] = data;

				// Send
				_group.sendToAllNeighbors(obj);
				return;
			}

			// Use socket mode
			if (_socket != null) {
				
				// Return if not connected
				if (!_socket.connected) {
					return;
				}

				// The package
				var bytes:ByteArray = new MonsterDebuggerData(id, data).bytes;

				// Send package
				_socket.writeUnsignedInt(bytes.length);
				_socket.writeBytes(bytes);
				_socket.flush();
			}
		}
		

		/**
		 * Socket received data
		 */
		private function dataHandler(event:ProgressEvent):void
		{
			// Clear and read the bytes
			_bytes.clear();
			_socket.readBytes(_bytes, 0, _socket.bytesAvailable);

			// Reset position
			_bytes.position = 0;
			processPackage();
		}


		/**
		 * Process package
		 */
		private function processPackage():void
		{
			// Return if null bytes available
			if (_bytes.bytesAvailable == 0) {
				return;
			}

			// Read the size
			if (_length == 0) {
				try {
					_length = _bytes.readUnsignedInt();
				} catch(e:Error) {
					_length = 0;
					return;
				}
				_package.clear();
			}

			// Load the data
			if (_package.length < _length && _bytes.bytesAvailable > 0) {
				
				// Get the data
				var l:uint = _bytes.bytesAvailable;
				if (l > _length - _package.length) {
					l = _length - _package.length;
				}
				_bytes.readBytes(_package, _package.length, l);
			}

			// Check if we have all the data
			if (_length != 0 && _package.length == _length) {
				
				// Log the data
				var item:MonsterDebuggerData = MonsterDebuggerData.read(_package);

				// Check if we should handle the call internaly
				if (item.id != null && item.id == MonsterDebuggerConstants.ID) {
					processData(item);
				}

				// Clear the old data
				_length = 0;
				_package.clear();
			}

			// Check if there is another package
			if (_length == 0 && _bytes.bytesAvailable > 0) {
				processPackage();
			}
		}


		/**
		 * Process data
		 */
		private function processData(item:MonsterDebuggerData):void
		{
			// Return if the debugger is connected to another debugger
			if (_isAnotherDebugger) {
				return;
			}

			if (item.data["command"] == MonsterDebuggerConstants.COMMAND_HELLO) {
				
				// You are connected to another debugger client stupid!
				_isAnotherDebugger = true;
				_group.removeEventListener(NetStatusEvent.NET_STATUS, onGroupUpdates);
				_group = null;
				_id = null;
				if (_onDisconnect != null) _onDisconnect(this);
				_onData = null;
				_onStart = null;
				_onDisconnect = null;
				return;
			}

			if (item.data["command"] == MonsterDebuggerConstants.COMMAND_INFO) {
				
				// Save info
				_playerType = item.data["playerType"];
				_playerVersion = item.data["playerVersion"];
				_isDebugger = item.data["isDebugger"];
				_isFlex = item.data["isFlex"];
				_fileLocation = item.data["fileLocation"];
				_fileTitle = item.data["fileTitle"];

				// Get the roots
				send(MonsterDebuggerConstants.ID, {command:MonsterDebuggerConstants.COMMAND_BASE});

				// Send the started command
				if (_onStart != null) _onStart(this);
				return;
			}

			// Call the data handler
			if (_onData != null) {
				_onData(item);
			}
		}
		

		/**
		 * Socket error
		 */
		private function disconnect(event:Event):void
		{
			_socket.removeEventListener(Event.CLOSE, disconnect);
			_socket.removeEventListener(IOErrorEvent.IO_ERROR, disconnect);
			_socket.removeEventListener(SecurityErrorEvent.SECURITY_ERROR, disconnect);
			_socket.removeEventListener(ProgressEvent.SOCKET_DATA, dataHandler);
			event.stopImmediatePropagation();
			if (_onDisconnect != null) _onDisconnect(this);
			_onData = null;
			_onStart = null;
			_onDisconnect = null;
		}
	}
}