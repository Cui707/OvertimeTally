import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

    expect(find.text('当月总加班'), findsOneWidget);
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
}
