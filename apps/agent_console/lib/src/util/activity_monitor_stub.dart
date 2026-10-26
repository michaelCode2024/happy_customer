/// 原生端由 Flutter 生命周期事件判断前台，这里不需要额外监听。
void startActivityMonitor(void Function(bool viewing) onChange) {
  onChange(true);
}

void stopActivityMonitor() {}
