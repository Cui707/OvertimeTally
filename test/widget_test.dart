import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:overtime_tally/core/date_x.dart';
import 'package:overtime_tally/data/in_memory_repository.dart';
import 'package:overtime_tally/main.dart';

void main() {
  testWidgets('应用启动后展示打卡页与四个底部入口', (tester) async {
    await tester.pumpWidget(
      OvertimeTallyApp(repository: InMemoryOvertimeRepository()),
    );
    await tester.pumpAndSettle();

    expect(find.text('上班打卡'), findsOneWidget);
    expect(find.text('下班打卡'), findsOneWidget);
    expect(find.text('当日信息'), findsOneWidget);

    expect(find.text('打卡'), findsOneWidget);
    expect(find.text('日历'), findsOneWidget);
    expect(find.text('调休'), findsOneWidget);
    expect(find.text('统计'), findsOneWidget);
  });

  testWidgets('切换到统计页展示月度统计面板', (tester) async {
    await tester.pumpWidget(
      OvertimeTallyApp(repository: InMemoryOvertimeRepository()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.bar_chart_outlined));
    await tester.pumpAndSettle();

    expect(find.text('当月加班总时长'), findsWidgets);
    expect(find.text('当月总加班费'), findsOneWidget);
    expect(find.text('剩余可调休'), findsOneWidget);
    expect(find.text('当月已调休'), findsOneWidget);
    expect(find.text('加班明细'), findsOneWidget);
  });

  testWidgets('切换到日历页与调休页', (tester) async {
    await tester.pumpWidget(
      OvertimeTallyApp(repository: InMemoryOvertimeRepository()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();
    expect(find.text('工作日加班'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.beach_access_outlined));
    await tester.pumpAndSettle();
    expect(find.text('新增调休记录'), findsOneWidget);
    expect(find.text('本月暂无调休记录'), findsOneWidget);
  });

  testWidgets('通过界面完成上班打卡后状态更新', (tester) async {
    await tester.pumpWidget(
      OvertimeTallyApp(repository: InMemoryOvertimeRepository()),
    );
    await tester.pumpAndSettle();

    expect(find.text('上班打卡'), findsOneWidget);
    await tester.tap(find.text('上班打卡'));
    await tester.pumpAndSettle();

    expect(find.text('重新打上班卡'), findsOneWidget);
    expect(find.text('上班打卡'), findsNothing);
  });

  testWidgets('界面录入超额调休会被拒绝并提示', (tester) async {
    await tester.pumpWidget(
      OvertimeTallyApp(repository: InMemoryOvertimeRepository()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.beach_access_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新增调休记录'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(1), '30');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.textContaining('超出当月可用额度'), findsOneWidget);
  });

  testWidgets('窄屏设备下统计与调休卡片不溢出', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      OvertimeTallyApp(repository: InMemoryOvertimeRepository()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.beach_access_outlined));
    await tester.pumpAndSettle();
    expect(find.text('可用调休'), findsOneWidget);
    expect(find.text('已调休'), findsOneWidget);
    expect(find.text('剩余'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.bar_chart_outlined));
    await tester.pumpAndSettle();
    expect(find.text('当月加班总时长'), findsWidgets);
  });

  testWidgets('通过界面删除当天打卡记录', (tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      OvertimeTallyApp(repository: InMemoryOvertimeRepository()),
    );
    await tester.pumpAndSettle();

    expect(find.text('删除当天打卡记录'), findsNothing);

    await tester.tap(find.text('上班打卡'));
    await tester.pumpAndSettle();
    expect(find.text('重新打上班卡'), findsOneWidget);
    expect(find.text('删除当天打卡记录'), findsOneWidget);

    await tester.tap(find.text('删除当天打卡记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('上班打卡'), findsOneWidget);
    expect(find.text('删除当天打卡记录'), findsNothing);
  });

  testWidgets('日历页长按日期可删除当天打卡记录', (tester) async {
    final repository = InMemoryOvertimeRepository();
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(OvertimeTallyApp(repository: repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('上班打卡'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.calendar_month_outlined));
    await tester.pumpAndSettle();

    final today = DateTime.now();
    await tester.longPress(find.text('${today.day}'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(await repository.dayRecordFor(dateOnly(today)), isNull);
  });
}
