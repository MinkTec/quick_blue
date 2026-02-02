import 'dart:math' as math;
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:quick_blue/quick_blue.dart';
import 'package:quick_blue_example/components/buffered_stream_builder.dart';
import 'package:quick_blue_example/device_page.dart';

class ScanResultList extends StatelessWidget {
  ScanResultList();

  @override
  Widget build(BuildContext context) => BufferedStreamBuilder<BlueScanResult>(
      stream: QuickBlue.scanResultStream, builder: _resultListBuilder);

  Widget _resultListBuilder(BuildContext context, Queue<BlueScanResult> elem) {
    Set<String> foundIds = {};
    Queue<BlueScanResult> filteredDevices = Queue();
    for (var e in elem) {
      if (!foundIds.contains(e.deviceId)) {
        filteredDevices.add(e);
        foundIds.add(e.deviceId);
      }
    }

    var sorted = filteredDevices.toList();
    sorted.sort((a, b) => b.rssi.compareTo(a.rssi));

    if (sorted.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: Column(
            children: [
              Icon(
                Icons.bluetooth_searching,
                size: 48,
                color: Colors.grey,
              ),
              SizedBox(height: 16),
              Text(
                'No devices found yet',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: NeverScrollableScrollPhysics(),
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        final device = sorted[index];
        return _DeviceListTile(
          device: device,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => DevicePage(device.deviceId, device.name),
            ),
          ),
        );
      },
    );
  }
}

class _DeviceListTile extends StatelessWidget {
  final BlueScanResult device;
  final VoidCallback onTap;

  const _DeviceListTile({
    required this.device,
    required this.onTap,
  });

  Color _getRssiColor(int rssi) {
    if (rssi > -60) return Colors.green;
    if (rssi > -80) return Colors.yellow;
    return Colors.red;
  }

  IconData _getRssiIcon(int rssi) {
    if (rssi > -60) return Icons.signal_cellular_alt;
    if (rssi > -80) return Icons.signal_cellular_alt_2_bar;
    return Icons.signal_cellular_alt_1_bar;
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: Colors.grey.shade800,
              width: 1,
            ),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.blue.shade900,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.bluetooth,
                  color: Colors.blue,
                ),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name.isNotEmpty ? device.name : 'Unknown Device',
                      style: Theme.of(context).textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                    SizedBox(height: 4),
                    Text(
                      device.deviceId,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey,
                          ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Row(
                    children: [
                      Icon(
                        _getRssiIcon(device.rssi),
                        color: _getRssiColor(device.rssi),
                        size: 20,
                      ),
                      SizedBox(width: 4),
                      Text(
                        '${device.rssi} dBm',
                        style: TextStyle(
                          color: _getRssiColor(device.rssi),
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Icon(
                    Icons.chevron_right,
                    color: Colors.grey,
                    size: 20,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
