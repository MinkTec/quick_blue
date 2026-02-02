import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:quick_blue/quick_blue.dart';
import 'package:quick_blue_example/components/data_display.dart';

typedef BleService = (String, List<String>);

class ServiceDisplay extends StatefulWidget {
  final String deviceId;

  ServiceDisplay(this.deviceId);

  @override
  State<ServiceDisplay> createState() => _ServiceDisplayState();
}

class _ServiceDisplayState extends State<ServiceDisplay> {
  StreamController<BleService>? _discoverServicesController =
      StreamController.broadcast();

  Queue<BleService> _discoveredServices = Queue<BleService>();

  @override
  void initState() {
    QuickBlue.setServiceHandler(
        (String deviceId, String serviceId, List<String> characteristicIds) {
      print("characteristicIds: $characteristicIds");
      if (!mounted) return;
      setState(() {
        // Prevent duplicates
        if (!_discoveredServices.any((s) => s.$1 == serviceId)) {
          _discoveredServices.add((serviceId, characteristicIds));
        }
      });
    });
    QuickBlue.discoverServices(widget.deviceId);
    super.initState();
  }

  @override
  void dispose() {
    _discoverServicesController?.close();
    QuickBlue.setServiceHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      for (var e in _discoveredServices)
        _DiscoveredServiceCard(e: e, widget: widget)
    ]);
  }
}

class _DiscoveredServiceCard extends StatefulWidget {
  _DiscoveredServiceCard({
    required this.e,
    required this.widget,
  }) : super(key: ValueKey(e.$1));

  final BleService e;
  final ServiceDisplay widget;

  @override
  State<_DiscoveredServiceCard> createState() => _DiscoveredServiceCardState();
}

class _DiscoveredServiceCardState extends State<_DiscoveredServiceCard> {
  final _controller = TextEditingController();

  Uint8List _commandBytes = Uint8List.fromList([0x00, 0x01, 0x00]);

  @override
  Widget build(BuildContext context) {
    return Card(
        margin: EdgeInsets.symmetric(horizontal: 0, vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(children: [
            Column(children: [
              Text(widget.e.$1,
                  textScaler: TextScaler.linear(1.2),
                  style: TextStyle(fontWeight: FontWeight.w600)),
              DataDisplay(widget.widget.deviceId)
            ]),
            Divider(thickness: 3, indent: 15, endIndent: 15),
            Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var c in widget.e.$2)
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(c),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          OutlinedButton(
                              onPressed: () => QuickBlue.writeValue(
                                  widget.widget.deviceId,
                                  widget.e.$1,
                                  c,
                                  _commandBytes,
                                  BleOutputProperty.withoutResponse),
                              child: Text("write value")),
                          OutlinedButton(
                              onPressed: () => QuickBlue.setNotifiable(
                                  widget.widget.deviceId,
                                  widget.e.$1,
                                  c,
                                  BleInputProperty.notification),
                              child: Text("set notifiable")),
                        ]),
                    SizedBox(height: 12)
                  ],
                ),
              Column(children: [
                SizedBox(
                    height: 50,
                    width: MediaQuery.of(context).size.width * 0.5,
                    child: TextField(
                      controller: _controller,
                      onChanged: (value) {
                        setState(() {
                          _commandBytes = Uint8List.fromList(value
                              .split(RegExp(r'[ ,]'))
                              .where((s) => s.isNotEmpty)
                              .map(int.parse)
                              .toList());
                          // Now you can use intList
                        });
                      },
                    )),
                Text("command bytes: ${_commandBytes.toString()}")
              ]),
              SizedBox(height: 12),
            ])
          ]),
        ));
  }
}
