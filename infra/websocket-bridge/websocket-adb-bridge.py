#!/usr/bin/env python3
"""
WebSocket ADB Bridge for Genymotion Cloud
Converts WebSocket ADB connection to local TCP ADB for standard adb compatibility
"""

import asyncio
import websockets
import socket
import sys
import os
import threading
import time
import logging
import ssl
from urllib.parse import urlparse

# Configure logging
logging.basicConfig(level=logging.INFO, format='[%(levelname)s] %(message)s')
logger = logging.getLogger(__name__)

class WebSocketADBBridge:
    def __init__(self, websocket_url: str, local_port: int = 5555):
        self.websocket_url = websocket_url
        self.local_port = local_port
        self.server_socket = None
        self.websocket = None
        self.running = False
        self.clients = []
        
    async def connect_websocket(self):
        """Connect to Genymotion WebSocket ADB"""
        try:
            logger.info(f"Connecting to WebSocket ADB: {self.websocket_url}")
            
            # Create SSL context that ignores certificate verification
            ssl_context = ssl.create_default_context()
            ssl_context.check_hostname = False
            ssl_context.verify_mode = ssl.CERT_NONE
            
            self.websocket = await websockets.connect(
                self.websocket_url,
                ssl=ssl_context,
                ping_interval=30,
                ping_timeout=10
            )
            logger.info("✓ WebSocket ADB connected successfully")
            return True
        except Exception as e:
            logger.error(f"✗ WebSocket connection failed: {e}")
            return False
    
    async def start_tcp_server(self):
        """Start local TCP server for ADB clients"""
        try:
            logger.info(f"Starting TCP server on localhost:{self.local_port}")
            
            # Create server socket
            self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self.server_socket.bind(('localhost', self.local_port))
            self.server_socket.listen(5)
            self.server_socket.settimeout(1.0)  # Non-blocking accept
            
            logger.info(f"✓ TCP server listening on localhost:{self.local_port}")
            
            while self.running:
                try:
                    client_socket, client_address = self.server_socket.accept()
                    logger.info(f"New ADB client connected from {client_address}")
                    
                    # Handle client in separate task
                    asyncio.create_task(self.handle_client(client_socket))
                    
                except socket.timeout:
                    continue  # Check if still running
                except Exception as e:
                    if self.running:
                        logger.error(f"Server accept error: {e}")
                    break
                    
        except Exception as e:
            logger.error(f"Failed to start TCP server: {e}")
    
    async def handle_client(self, client_socket):
        """Handle individual ADB client connection"""
        logger.info(f"Handling new ADB client connection")
        try:
            self.clients.append(client_socket)
            client_socket.settimeout(5.0)  # Longer timeout for handshake
            
            while self.running and self.websocket:
                try:
                    # Read from ADB client (non-blocking)
                    data = client_socket.recv(8192)
                    if not data:
                        logger.debug("Client disconnected")
                        break
                        
                    logger.debug(f"Client->WebSocket: {len(data)} bytes")
                    # Forward to WebSocket
                    await self.websocket.send(data)
                    
                except socket.timeout:
                    continue
                except Exception as e:
                    logger.debug(f"Client read error: {e}")
                    break
                    
        except Exception as e:
            logger.error(f"Client handler error: {e}")
        finally:
            try:
                client_socket.close()
                if client_socket in self.clients:
                    self.clients.remove(client_socket)
                logger.debug("Client connection closed")
            except:
                pass
    
    async def websocket_forwarder(self):
        """Forward WebSocket messages to TCP clients"""
        try:
            while self.running and self.websocket:
                try:
                    # Receive from WebSocket
                    message = await asyncio.wait_for(self.websocket.recv(), timeout=2.0)
                    
                    if self.clients:
                        logger.debug(f"WebSocket->Clients: {len(message)} bytes to {len(self.clients)} clients")
                    
                    # Forward to all ADB clients
                    for client_socket in self.clients[:]:  # Copy to avoid modification during iteration
                        try:
                            # Use non-blocking send
                            client_socket.settimeout(0.5)
                            client_socket.send(message)
                        except Exception as e:
                            logger.debug(f"Failed to send to client: {e}")
                            # Remove dead connections
                            try:
                                self.clients.remove(client_socket)
                                client_socket.close()
                            except:
                                pass
                                
                except asyncio.TimeoutError:
                    continue
                except websockets.exceptions.ConnectionClosed:
                    logger.warn("WebSocket connection closed")
                    break
                except Exception as e:
                    logger.error(f"WebSocket receive error: {e}")
                    break
                    
        except Exception as e:
            logger.error(f"WebSocket forwarder error: {e}")
    
    async def run_bridge(self):
        """Main bridge execution"""
        logger.info("Starting WebSocket ADB Bridge...")
        self.running = True
        
        # Connect to WebSocket
        if not await self.connect_websocket():
            return False
        
        # Start TCP server and WebSocket forwarder concurrently
        try:
            await asyncio.gather(
                self.start_tcp_server(),
                self.websocket_forwarder()
            )
        except Exception as e:
            logger.error(f"Bridge execution error: {e}")
            return False
        
        return True
    
    def stop_bridge(self):
        """Stop the bridge"""
        logger.info("Stopping WebSocket ADB Bridge...")
        self.running = False
        
        # Close server socket
        if self.server_socket:
            try:
                self.server_socket.close()
            except:
                pass
        
        # Close all client connections
        for client_socket in self.clients[:]:
            try:
                client_socket.close()
            except:
                pass
        self.clients.clear()
        
        # Close WebSocket
        if self.websocket:
            try:
                asyncio.create_task(self.websocket.close())
            except:
                pass

async def main():
    """Main execution function"""
    # Get WebSocket URL from environment or connection file
    websocket_url = os.environ.get('GENYMOTION_WEBSOCKET_URL')
    if not websocket_url:
        try:
            with open('/tmp/genymotion_connection.env', 'r') as f:
                for line in f:
                    if 'GENYMOTION_ADB_URL=' in line or 'publicAdbUrl=' in line:
                        websocket_url = line.split('=', 1)[1].strip().strip('"')
                        break
        except FileNotFoundError:
            pass
    
    if not websocket_url:
        logger.error("WebSocket URL not found. Set GENYMOTION_WEBSOCKET_URL or ensure connection file exists.")
        return 1
    
    # Clean URL format
    if websocket_url.startswith('wss://'):
        ws_url = websocket_url
    else:
        logger.error(f"Invalid WebSocket URL format: {websocket_url}")
        return 1
    
    logger.info(f"WebSocket ADB Bridge Configuration:")
    logger.info(f"  WebSocket URL: {ws_url}")
    logger.info(f"  Local TCP Port: 5555")
    logger.info(f"  ADB Command: adb connect localhost:5555")
    
    # Create and run bridge
    bridge = WebSocketADBBridge(ws_url, 5555)
    
    try:
        success = await bridge.run_bridge()
        return 0 if success else 1
    except KeyboardInterrupt:
        logger.info("Bridge interrupted by user")
        return 0
    except Exception as e:
        logger.error(f"Bridge failed: {e}")
        return 1
    finally:
        bridge.stop_bridge()

if __name__ == "__main__":
    try:
        exit_code = asyncio.run(main())
        sys.exit(exit_code)
    except KeyboardInterrupt:
        logger.info("Bridge stopped by user")
        sys.exit(0)