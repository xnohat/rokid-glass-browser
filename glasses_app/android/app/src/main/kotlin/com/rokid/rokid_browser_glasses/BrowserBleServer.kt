package com.rokid.rokid_browser_glasses

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import java.util.LinkedList
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * BLE Peripheral (GATT server) for the glasses side — replaces RFCOMM BrowserBtClient.
 * The glasses advertise a GATT service; the iPhone (Central) connects.
 *
 * Protocol (identical to the original app):
 *   * Newline-delimited JSON messages.
 *   * TX characteristic  (phone -> glasses): WRITE, reassembled on newline.
 *   * RX characteristic  (glasses -> phone): NOTIFY, chunked to MTU-3, sent serially.
 *   * Ping keepalive filtered out.
 */
class BrowserBleServer(
    private val context: Context,
    private val onMessage: (String) -> Unit,
    private val onStatus: (String) -> Unit
) {
    companion object {
        private const val TAG = "BrowserBLEServer"
        val SERVICE_UUID: UUID = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        val TX_CHAR_UUID: UUID = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234560001")
        val RX_CHAR_UUID: UUID = UUID.fromString("a1b2c3d4-e5f6-7890-abcd-ef1234560002")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val DEFAULT_CHUNK = 20 // ATT default MTU 23 - 3
        private const val MAX_MSG_BYTES = 64 * 1024
    }

    private var gattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var rxChar: BluetoothGattCharacteristic? = null
    private var connectedDevice: BluetoothDevice? = null
    private var notifyEnabled = false
    private var mtu = 23

    private val running = AtomicBoolean(false)
    private val rxBuffer = StringBuilder()

    // Serial notify queue: BLE allows one outstanding notification at a time.
    private val notifyQueue = LinkedList<ByteArray>()
    private var notifyInFlight = false
    private val notifyLock = Any()

    @SuppressLint("MissingPermission")
    fun start() {
        if (running.getAndSet(true)) return
        val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter = manager.adapter
        if (adapter == null || !adapter.isEnabled) {
            onStatus("bluetooth_off")
            running.set(false)
            return
        }

        // Give the adapter a recognisable name so the iOS central can match us by
        // localName in the scan response even if the UUID filter misses.
        try {
            if (adapter.name?.startsWith("RokidBrowser") != true) {
                adapter.name = "RokidBrowser"
            }
        } catch (_: Exception) {}

        advertiser = adapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            Log.e(TAG, "Device does NOT support BLE advertising")
            onStatus("advertise_unsupported")
            running.set(false)
            return
        }

        // GATT server
        gattServer = manager.openGattServer(context, gattCallback)
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        val tx = BluetoothGattCharacteristic(
            TX_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
            BluetoothGattCharacteristic.PERMISSION_WRITE
        )
        val rx = BluetoothGattCharacteristic(
            RX_CHAR_UUID,
            BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_READ
        )
        val cccd = BluetoothGattDescriptor(
            CCCD_UUID,
            BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE
        )
        rx.addDescriptor(cccd)
        rxChar = rx

        service.addCharacteristic(tx)
        service.addCharacteristic(rx)
        // Advertising is started from onServiceAdded (below), NOT here — the GATT
        // DB must be ready before we advertise, otherwise an iOS central that
        // connects on the first advertisement can fail service discovery.
        gattServer?.addService(service)

        onStatus("listening")
    }

    @SuppressLint("MissingPermission")
    private fun startAdvertising() {
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setConnectable(true)
            .setTimeout(0)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .build()
        // Primary packet: the 128-bit service UUID (a 128-bit UUID nearly fills the
        // 31-byte payload, so the device name must NOT go here).
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        // Scan response: the device name only. Gives the iOS central a second,
        // independent way to recognise us (localName) when a filtered scan misses
        // the UUID in the primary packet.
        val scanResponse = AdvertiseData.Builder()
            .setIncludeDeviceName(true)
            .build()
        advertiser?.startAdvertising(settings, data, scanResponse, advertiseCallback)
    }

    @SuppressLint("MissingPermission")
    fun stop() {
        running.set(false)
        try { advertiser?.stopAdvertising(advertiseCallback) } catch (_: Exception) {}
        try { gattServer?.close() } catch (_: Exception) {}
        gattServer = null
        connectedDevice = null
        notifyEnabled = false
        synchronized(notifyLock) { notifyQueue.clear(); notifyInFlight = false }
    }

    /** Enqueue a JSON line to send to the phone. */
    fun send(msg: String) {
        if (!notifyEnabled) return
        var line = msg
        if (!line.endsWith("\n")) line += "\n"
        val bytes = line.toByteArray(Charsets.UTF_8)
        val chunkSize = (mtu - 3).coerceAtLeast(DEFAULT_CHUNK)
        var offset = 0
        synchronized(notifyLock) {
            while (offset < bytes.size) {
                val end = minOf(offset + chunkSize, bytes.size)
                notifyQueue.add(bytes.copyOfRange(offset, end))
                offset = end
            }
        }
        pumpNotify()
    }

    @SuppressLint("MissingPermission")
    private fun pumpNotify() {
        val server = gattServer ?: return
        val device = connectedDevice ?: return
        val ch = rxChar ?: return
        synchronized(notifyLock) {
            if (notifyInFlight) return
            val next = notifyQueue.poll() ?: return
            notifyInFlight = true
            @Suppress("DEPRECATION")
            run {
                ch.value = next
                server.notifyCharacteristicChanged(device, ch, false)
            }
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            Log.d(TAG, "Advertising started")
        }
        override fun onStartFailure(errorCode: Int) {
            Log.e(TAG, "Advertising failed: $errorCode")
            onStatus("advertise_failed:$errorCode")
        }
    }

    private val gattCallback = object : BluetoothGattServerCallback() {
        @SuppressLint("MissingPermission")
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            // GATT DB is ready — NOW it is safe to advertise.
            if (status == BluetoothGatt.GATT_SUCCESS && running.get()) {
                startAdvertising()
            } else {
                Log.e(TAG, "onServiceAdded failed status=$status")
            }
        }

        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothGatt.STATE_CONNECTED) {
                connectedDevice = device
                val name = device.name ?: device.address
                onStatus("connected:$name")
            } else if (newState == BluetoothGatt.STATE_DISCONNECTED) {
                if (device == connectedDevice) {
                    connectedDevice = null
                    notifyEnabled = false
                    rxBuffer.setLength(0)
                    synchronized(notifyLock) { notifyQueue.clear(); notifyInFlight = false }
                    onStatus("disconnected")
                    // Resume advertising for reconnect.
                    if (running.get()) startAdvertising()
                }
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtuValue: Int) {
            mtu = mtuValue
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (characteristic.uuid == TX_CHAR_UUID) {
                handleIncoming(value)
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            if (descriptor.uuid == CCCD_UUID) {
                notifyEnabled = value.isNotEmpty() &&
                    value[0].toInt() == BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE[0].toInt()
                if (notifyEnabled) onStatus("connected:${device.name ?: device.address}")
            }
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            synchronized(notifyLock) { notifyInFlight = false }
            pumpNotify()
        }
    }

    private fun handleIncoming(chunk: ByteArray) {
        val s = String(chunk, Charsets.UTF_8)
        rxBuffer.append(s)
        if (rxBuffer.length > MAX_MSG_BYTES) rxBuffer.setLength(0) // overflow guard
        var idx = rxBuffer.indexOf("\n")
        while (idx >= 0) {
            val line = rxBuffer.substring(0, idx).trim()
            rxBuffer.delete(0, idx + 1)
            if (line.isNotEmpty() && !line.contains("\"type\":\"ping\"")) {
                onMessage(line)
            }
            idx = rxBuffer.indexOf("\n")
        }
    }
}
