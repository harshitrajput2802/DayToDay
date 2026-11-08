import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import 'package:excel/excel.dart' hide Border;
import 'package:flutter/material.dart' as flutter;

import 'package:file_saver/file_saver.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

/// Shown in the About dialog. Keep in sync with pubspec.yaml.
const String kAppVersion = '1.0.2';

final FlutterLocalNotificationsPlugin backupNotifications =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Restore the saved light/dark choice before the first frame (no flicker).
  try {
    themeModeNotifier.value =
        await LocalTransactionDatabase.instance.loadThemeMode();
  } catch (e) {
    debugPrint('Could not load theme mode: $e');
  }

  if (!kIsWeb) {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const initializationSettings = InitializationSettings(
      android: androidSettings,
    );

    await backupNotifications.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse:
          (NotificationResponse response) async {
        final fileUri = response.payload;

        if (fileUri != null && fileUri.isNotEmpty) {
          final result = await OpenFilex.open(fileUri);
          debugPrint('Open backup result: ${result.message}');
        }
      },
    );

    final androidPlugin = backupNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.requestNotificationsPermission();
  }

  runApp(const MyApp());
}

Future<void> showBackupNotification(String fileUri) async {
  if (kIsWeb) return;

  const androidDetails = AndroidNotificationDetails(
    'daytoday_backup_channel',
    'Excel Backups',
    channelDescription: 'Notifications for completed Excel backups',
    importance: Importance.high,
    priority: Priority.high,
    icon: '@mipmap/ic_launcher',
  );

  const notificationDetails = NotificationDetails(
    android: androidDetails,
  );

  await backupNotifications.show(
    id: 1001,
    title: 'Excel backup downloaded',
    body: 'Tap here to open your transaction spreadsheet.',
    notificationDetails: notificationDetails,
    payload: fileUri,
  );
}

// Device-local database. Transaction data is not sent to any backend.
class LocalTransactionDatabase {
  LocalTransactionDatabase._();
  static final instance = LocalTransactionDatabase._();
  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    final dir = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dir, 'daytoday_local.db'),
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE transactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            TranDate TEXT NOT NULL, Description TEXT NOT NULL,
            Amount REAL NOT NULL, Type TEXT NOT NULL, Mode TEXT NOT NULL,
            Remarks TEXT, Other TEXT, CategoryName TEXT,
            CreationDate TEXT NOT NULL, IsDeleted INTEGER NOT NULL DEFAULT 0,
            Image1Path TEXT, Image2Path TEXT,
            Image1Blob BLOB, Image2Blob BLOB
          )
        ''');
      },
      // Small key/value table for app settings (theme mode). Created on every
      // open if missing, so no database version bump / migration is needed.
      onOpen: (db) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS app_settings (
            setting_key TEXT PRIMARY KEY,
            setting_value TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE transactions ADD COLUMN Image1Path TEXT');
          await db.execute('ALTER TABLE transactions ADD COLUMN Image2Path TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE transactions ADD COLUMN Image1Blob BLOB');
          await db.execute('ALTER TABLE transactions ADD COLUMN Image2Blob BLOB');
          // Migrate images saved by earlier versions from path files to SQLite BLOBs.
          final legacyRows = await db.query('transactions',
              columns: ['id', 'Image1Path', 'Image2Path']);
          for (final row in legacyRows) {
            final id = row['id'] as int;
            final update = <String, Object?>{};
            for (final slot in [1, 2]) {
              final oldPath = row['Image${slot}Path']?.toString();
              if (oldPath != null && oldPath.isNotEmpty) {
                final file = File(oldPath);
                if (await file.exists()) {
                  update['Image${slot}Blob'] = await file.readAsBytes();
                }
              }
            }
            if (update.isNotEmpty) {
              await db.update('transactions', update,
                  where: 'id = ?', whereArgs: [id]);
            }
          }
        }
      },
    );
    return _db!;
  }

  /// Lightweight list query: images are NOT loaded, only HasImage1/HasImage2 flags.
  /// Set [includeDeleted] to true for full backups.
  Future<List<Map<String, dynamic>>> getTransactions({
    DateTime? from,
    DateTime? to,
    bool includeDeleted = false,
  }) async {
    final db = await database;
    var where = includeDeleted ? '1 = 1' : 'IsDeleted = 0';
    final args = <Object?>[];
    if (from != null) {
      where += ' AND TranDate >= ?';
      args.add(_date(from));
    }
    if (to != null) {
      where += ' AND TranDate <= ?';
      args.add(_date(to));
    }
    return db.query(
      'transactions',
      columns: [
        'id', 'TranDate', 'Description', 'Amount', 'Type', 'Mode', 'Remarks',
        'Other', 'CategoryName', 'CreationDate', 'IsDeleted',
        '(Image1Blob IS NOT NULL) AS HasImage1',
        '(Image2Blob IS NOT NULL) AS HasImage2',
      ],
      where: where,
      whereArgs: args,
      orderBy: 'TranDate ASC, id ASC',
    );
  }

  Future<Map<String, dynamic>?> getImages(int id) async {
    final db = await database;
    final rows = await db.query('transactions',
        columns: ['Image1Blob', 'Image2Blob'],
        where: 'id = ?',
        whereArgs: [id],
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<int> insert(Map<String, dynamic> row) async =>
      (await database).insert('transactions', row,
          conflictAlgorithm: ConflictAlgorithm.abort);

  Future<int> update(int id, Map<String, dynamic> row) async =>
      (await database)
          .update('transactions', row, where: 'id = ?', whereArgs: [id]);

  Future<int> softDelete(int id) async => (await database).update(
      'transactions', {'IsDeleted': 1},
      where: 'id = ?', whereArgs: [id]);

  Future<ThemeMode> loadThemeMode() async {
    final db = await database;
    final rows = await db.query('app_settings',
        where: 'setting_key = ?', whereArgs: ['theme_mode'], limit: 1);
    if (rows.isEmpty) return ThemeMode.light;
    return rows.first['setting_value'] == 'dark'
        ? ThemeMode.dark
        : ThemeMode.light;
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    final db = await database;
    await db.insert(
      'app_settings',
      {
        'setting_key': 'theme_mode',
        'setting_value': mode == ThemeMode.dark ? 'dark' : 'light',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

// --------------------------------------------------
// THEME (light + dark share ONE definition)
// --------------------------------------------------

/// Current theme mode. Changing it rebuilds MaterialApp instantly.
final ValueNotifier<ThemeMode> themeModeNotifier =
    ValueNotifier<ThemeMode>(ThemeMode.light);

/// Switch theme and remember the choice on the device.
Future<void> setThemeMode(ThemeMode mode) async {
  themeModeNotifier.value = mode;
  try {
    await LocalTransactionDatabase.instance.saveThemeMode(mode);
  } catch (e) {
    debugPrint('Could not save theme mode: $e');
  }
}

/// App-specific colors that Material's ColorScheme has no slot for.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.income,
    required this.expense,
    required this.cardBorder,
    required this.tableHeader,
    required this.accent,
    required this.textSecondary,
  });

  final Color income;
  final Color expense;
  final Color cardBorder;
  final Color tableHeader;
  final Color accent;
  final Color textSecondary;

  static AppColors of(BuildContext context) =>
      Theme.of(context).extension<AppColors>()!;

  @override
  AppColors copyWith({
    Color? income,
    Color? expense,
    Color? cardBorder,
    Color? tableHeader,
    Color? accent,
    Color? textSecondary,
  }) {
    return AppColors(
      income: income ?? this.income,
      expense: expense ?? this.expense,
      cardBorder: cardBorder ?? this.cardBorder,
      tableHeader: tableHeader ?? this.tableHeader,
      accent: accent ?? this.accent,
      textSecondary: textSecondary ?? this.textSecondary,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      income: Color.lerp(income, other.income, t)!,
      expense: Color.lerp(expense, other.expense, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      tableHeader: Color.lerp(tableHeader, other.tableHeader, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
    );
  }
}

/// Builds the light or dark ThemeData from one palette table.
ThemeData buildAppTheme({required bool dark}) {
  // ---- palette --------------------------------------------------------
  final background = dark ? const Color(0xFF1F1B18) : const Color(0xFFEDE9E5);
  final surface = dark ? const Color(0xFF2A2521) : const Color(0xFFF7F5F3);
  final tableHeader = dark ? const Color(0xFF332D28) : const Color(0xFFE3DED9);
  final border = dark ? const Color(0xFF3A332D) : const Color(0xFFE5E1DD);
  final inputFill = dark ? const Color(0xFF2A2521) : Colors.white;
  final primary = dark ? const Color(0xFFC98B6B) : const Color(0xFF885843);
  final onPrimary = dark ? const Color(0xFF2A1A12) : Colors.white;
  final accent = dark ? const Color(0xFFC9B8AB) : const Color(0xFF5B514A);
  final textPrimary = dark ? const Color(0xFFF2EDE8) : const Color(0xFF353330);
  final textSecondary =
      dark ? const Color(0xFFA89E95) : const Color(0xFF877C74);
  final income = dark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A);
  final expense = dark ? const Color(0xFFF87171) : const Color(0xFFEF4444);

  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF885843),
    brightness: dark ? Brightness.dark : Brightness.light,
  ).copyWith(
    primary: primary,
    onPrimary: onPrimary,
    secondary: accent,
    onSecondary: dark ? const Color(0xFF1F1B18) : Colors.white,
    surface: surface,
    onSurface: textPrimary,
    onSurfaceVariant: textSecondary,
    outline: border,
    outlineVariant: border,
    error: expense,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: dark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: background,
    dividerColor: border,
    extensions: <ThemeExtension<dynamic>>[
      AppColors(
        income: income,
        expense: expense,
        cardBorder: border,
        tableHeader: tableHeader,
        accent: accent,
        textSecondary: textSecondary,
      ),
    ],
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: textPrimary,
      elevation: 0,
      surfaceTintColor: surface,
    ),
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: inputFill,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: primary, width: 1.5),
      ),
    ),
    // Default ElevatedButton = secondary style (Backup). "New" overrides to primary.
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: surface,
        foregroundColor: primary,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: primary,
        foregroundColor: onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: primary),
    ),
  );
}

// --------------------------------------------------
// APP
// --------------------------------------------------

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Day2Day',
          theme: buildAppTheme(dark: false),
          darkTheme: buildAppTheme(dark: true),
          themeMode: mode,
          home: const HomePage(),
        );
      },
    );
  }
}

// --------------------------------------------------
// LOADING SKELETON
// --------------------------------------------------

/// Pulsing placeholder rows shown while transactions load.
class _SkeletonList extends StatefulWidget {
  const _SkeletonList();

  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final app = AppColors.of(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final base =
            Color.lerp(app.cardBorder, scheme.surface, 0.15 + 0.6 * _controller.value)!;
        Widget bar(double w, double h) => Container(
              width: w,
              height: h,
              decoration: BoxDecoration(
                color: base,
                borderRadius: BorderRadius.circular(6),
              ),
            );
        return ListView.builder(
          physics: const NeverScrollableScrollPhysics(),
          itemCount: 6,
          itemBuilder: (context, i) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              height: 66,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: app.cardBorder),
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: base,
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [bar(150, 12), const SizedBox(height: 8), bar(96, 10)],
                    ),
                  ),
                  bar(62, 14),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// --------------------------------------------------
// QUICK DATE RANGES + ANIMATED AMOUNT
// --------------------------------------------------

enum QuickRange { today, thisWeek, thisMonth, lastMonth, thisYear, custom }

/// Shows a rupee amount that counts up from 0 on first display and animates
/// smoothly from the old value to the new one whenever [value] changes.
/// When [hidden] is true it shows masked text instead.
class CountUpAmount extends StatelessWidget {
  const CountUpAmount({
    super.key,
    required this.value,
    required this.style,
    this.hidden = false,
    this.duration = const Duration(milliseconds: 700),
  });

  final double value;
  final TextStyle style;
  final bool hidden;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    if (hidden) return Text('₹ ••••', style: style);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: value),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, animated, _) =>
          Text('₹${animated.toStringAsFixed(2)}', style: style),
    );
  }
}

// --------------------------------------------------
// HOME PAGE
// --------------------------------------------------
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final String message = 'Spend Smart. Live Better!';

  final ScrollController _headerHorizontalController = ScrollController();

  final ScrollController _bodyHorizontalController = ScrollController();

  bool _isSyncingHorizontalScroll = false;

  // Transactions currently shown (after date filter).
  final List<Map<String, dynamic>> transactions = [];

  // Full active history is retained so balances stay cumulative after date filtering.
  final List<Map<String, dynamic>> balanceTransactions = [];

  final TextEditingController descriptionSearchController =
      TextEditingController();
  String descriptionSearch = '';

  // UI state.
  bool _hideAmounts = false; // eye button in the app bar (session only)
  String? _typeFilter; // 'income' | 'expense' | null (tap the summary cards)
  QuickRange _quickRange = QuickRange.thisMonth;
  DateTime? _appliedFrom; // date range the list was last loaded with
  DateTime? _appliedTo;
  bool _loading = true; // true until the first load finishes
  bool _filtersCollapsed = false;
  bool _fabExtended = true;
  final ScrollController _listController = ScrollController();

  // Search dates (default: current month). The filter is applied on startup
  // so the From/To fields always match what the list shows.
  DateTime fromDate = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime toDate = DateTime.now();

  @override
  void initState() {
    super.initState();

    _headerHorizontalController.addListener(() {
      _syncHorizontalScroll(
        _headerHorizontalController,
        _bodyHorizontalController,
      );
    });

    _bodyHorizontalController.addListener(() {
      _syncHorizontalScroll(
        _bodyHorizontalController,
        _headerHorizontalController,
      );
    });

    /*_headerHorizontalController.addListener(() {
       if (_bodyHorizontalController.hasClients &&
           _bodyHorizontalController.offset !=
               _headerHorizontalController.offset) {
         _bodyHorizontalController.jumpTo(
           _headerHorizontalController.offset,
         );
       }
     });
   
     _bodyHorizontalController.addListener(() {
       if (_headerHorizontalController.hasClients &&
           _headerHorizontalController.offset !=
               _bodyHorizontalController.offset) {
         _headerHorizontalController.jumpTo(
           _bodyHorizontalController.offset,
         );
       }
     });*/

    _listController.addListener(_onListScroll);
    fetchTransactions(searchByDate: true);
  }

  void _onListScroll() {
    if (!_listController.hasClients) return;
    final direction = _listController.position.userScrollDirection;
    final shouldExtend =
        _listController.offset < 40 || direction == ScrollDirection.forward;
    if (shouldExtend != _fabExtended) {
      setState(() => _fabExtended = shouldExtend);
    }
  }

  @override
  void dispose() {
    _listController.dispose();
    descriptionSearchController.dispose();

    _headerHorizontalController.dispose();
    _bodyHorizontalController.dispose();

    super.dispose();
  }

  void _syncHorizontalScroll(ScrollController source,ScrollController target,) {

      if (_isSyncingHorizontalScroll || !source.hasClients || !target.hasClients) {
        return;
      }

      _isSyncingHorizontalScroll = true;

      final targetPosition = target.position;
      final offset = source.offset
          .clamp(
            targetPosition.minScrollExtent,
            targetPosition.maxScrollExtent,
          )
          .toDouble();

      target.jumpTo(offset);
      _isSyncingHorizontalScroll = false;
  }

  double _columnWidth(int index) {
  switch (index) {
    case 0:  return 140; // Transaction No.
    case 1:  return 175; // Transaction Date
    case 2:  return 200; // Description
    case 3:  return 120; // Amount
    case 4:  return 110; // Type
    case 5:  return 110; // Mode
    case 6:  return 180; // Remarks
    case 7:  return 160; // Other
    case 8:  return 180; // CategoryName
    case 9:  return 145; // Balance
    case 10: return 200; // Actions
    default: return 120;
  }
}

List<TableColumnWidth> _sharedColumnWidths() {
  return List<TableColumnWidth>.generate(
    11,
    (index) => FixedColumnWidth(_columnWidth(index)),
  );
}

Widget _headerCell(String text, int index) {
  return Container(
    width: _columnWidth(index),
    height: 46,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: const TextStyle(fontWeight: FontWeight.bold),
    ),
  );
}

Widget _bodyCell(Widget child, int index) {
  return Container(
    width: _columnWidth(index),
    constraints: const BoxConstraints(minHeight: 48),
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    child: child,
  );
}

Widget _bodyText(String value, int index) {
  return _bodyCell(
    Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
    ),
    index,
  );
}

Widget _tableCellText(int columnIndex, String value,) {
  return SizedBox(
    width: _columnWidth(columnIndex),
    child: Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
    ),
  );
}

  // --------------------------------------------------
  // LOAD TRANSACTIONS (local database)
  // --------------------------------------------------

  Future<void> fetchTransactions({bool searchByDate = false}) async {
    try {
      DateTime? from, to;
      if (searchByDate) {
        from = DateTime(fromDate.year, fromDate.month, fromDate.day);
        to = DateTime(toDate.year, toDate.month, toDate.day);
        if (from.isAfter(to)) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('From date cannot be after To date')));
          return;
        }
      }
      if (!_loading && mounted) setState(() => _loading = true);
      final all = await LocalTransactionDatabase.instance.getTransactions();
      final visible = searchByDate
          ? await LocalTransactionDatabase.instance
              .getTransactions(from: from, to: to)
          : all;
      if (!mounted) return;
      setState(() {
        transactions
          ..clear()
          ..addAll(visible.map((e) => Map<String, dynamic>.from(e)));
        balanceTransactions
          ..clear()
          ..addAll(all.map((e) => Map<String, dynamic>.from(e)));
        _appliedFrom = from;
        _appliedTo = to;
        _loading = false;
      });
    } catch (e, st) {
      debugPrint('LOCAL FETCH ERROR: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load local transactions: $e')));
    }
  }

  // --------------------------------------------------
  // DATE PICKER
  // --------------------------------------------------

  Future<DateTime?> pickDate(DateTime initialDate) async {
    return await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
  }

  Future<void> selectFromDate() async {
    final picked = await pickDate(fromDate);
    if (picked != null) {
      setState(() => fromDate = picked);
    }
  }

  Future<void> selectToDate() async {
    final picked = await pickDate(toDate);
    if (picked != null) {
      setState(() => toDate = picked);
    }
  }

  // --------------------------------------------------
  // DATE FORMAT
  // --------------------------------------------------

  String formatDate(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year.toString();
    return '$day-$month-$year';
  }
  
  String formatTransactionDate(DateTime date) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];

    String day = date.day.toString().padLeft(2, '0');
    String month = months[date.month - 1];
    String year = date.year.toString();

    return '$day $month $year';
  }

  // --------------------------------------------------
  // OPEN NEW / EDIT TRANSACTION PAGE
  // --------------------------------------------------

  // Reload using the date filter that is currently selected.
  Future<void> _reload() => fetchTransactions(searchByDate: true);

  /// Opens the transaction form as a full page.
  Future<bool?> _openAddEdit({Map<String, dynamic>? transaction}) {
    return Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AddExpensePage(transaction: transaction),
      ),
    );
  }

  Future<void> openNewTransaction() async {
    final saved = await _openAddEdit();
    if (saved == true) await _reload();
  }

  Future<void> openEditTransaction(Map<String, dynamic> transaction) async {
    final saved = await _openAddEdit(transaction: transaction);
    if (saved == true) await _reload();
  }

  // --------------------------------------------------
  // FILTER + TOTALS
  // --------------------------------------------------

  List<Map<String, dynamic>> get filteredTransactions {
    final query = descriptionSearch.trim().toLowerCase();
    if (query.isEmpty) return transactions;
    return transactions.where((transaction) {
      final description =
          transaction['Description']?.toString().toLowerCase() ?? '';
      return description.contains(query);
    }).toList();
  }

  /// Search filter + the Income/Expenses card filter. Used by the list/table.
  /// (Totals above the list keep using [filteredTransactions] so they never
  /// change just because a card filter is active.)
  List<Map<String, dynamic>> get visibleTransactions {
    return filteredTransactions.where((t) {
      if (_typeFilter != null) {
        final ok = _typeFilter == 'income' ? _isIncome(t) : _isExpense(t);
        if (!ok) return false;
      }
      return true;
    }).toList();
  }

  double _amountOf(Map<String, dynamic> transaction) {
    return double.tryParse(transaction['Amount']?.toString() ?? '') ?? 0.0;
  }

  bool _isIncome(Map<String, dynamic> transaction) {
    return (transaction['Type']?.toString().trim().toLowerCase() ?? '') ==
        'income';
  }

  bool _isExpense(Map<String, dynamic> transaction) {
    return (transaction['Type']?.toString().trim().toLowerCase() ?? '') ==
        'expense';
  }

  double get totalIncome => filteredTransactions
      .where(_isIncome)
      .fold(0.0, (sum, transaction) => sum + _amountOf(transaction));

  double get totalExpenses => filteredTransactions
      .where(_isExpense)
      .fold(0.0, (sum, transaction) => sum + _amountOf(transaction));

  double get netBalance => totalIncome - totalExpenses;

  // Cumulative running balance over the full active history.
  Map<String, double> get runningBalances {
    final chronological = List<Map<String, dynamic>>.from(balanceTransactions);
    chronological.sort((a, b) {
      final dateA =
          DateTime.tryParse(a['TranDate']?.toString() ?? '') ?? DateTime(2000);
      final dateB =
          DateTime.tryParse(b['TranDate']?.toString() ?? '') ?? DateTime(2000);
      final dateComparison = dateA.compareTo(dateB);
      if (dateComparison != 0) return dateComparison;
      final idA = int.tryParse(a['id']?.toString() ?? '') ?? 0;
      final idB = int.tryParse(b['id']?.toString() ?? '') ?? 0;
      return idA.compareTo(idB);
    });

    var balance = 0.0;
    final result = <String, double>{};
    for (final transaction in chronological) {
      if (_isIncome(transaction)) {
        balance += _amountOf(transaction);
      } else if (_isExpense(transaction)) {
        balance -= _amountOf(transaction);
      }
      result[transaction['id'].toString()] = balance;
    }
    return result;
  }

  String _formatAmount(double amount) => '₹${amount.toStringAsFixed(2)}';

  // --------------------------------------------------
  // HIDE / SHOW AMOUNTS
  // --------------------------------------------------

  String _displayAmount(double amount) =>
      _hideAmounts ? '₹ ••••' : _formatAmount(amount);

  // --------------------------------------------------
  // QUICK DATE RANGES
  // --------------------------------------------------

  void _applyQuickRange(QuickRange range) {
    if (range == QuickRange.custom) {
      setState(() => _quickRange = QuickRange.custom);
      return;
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    late DateTime from;
    late DateTime to;
    switch (range) {
      case QuickRange.today:
        from = today;
        to = today;
      case QuickRange.thisWeek:
        from = today.subtract(Duration(days: today.weekday - 1)); // Monday
        to = today;
      case QuickRange.thisMonth:
        from = DateTime(today.year, today.month, 1);
        to = today;
      case QuickRange.lastMonth:
        from = DateTime(today.year, today.month - 1, 1);
        to = DateTime(today.year, today.month, 0); // last day of last month
      case QuickRange.thisYear:
        from = DateTime(today.year, 1, 1);
        to = today;
      case QuickRange.custom:
        return;
    }
    setState(() {
      _quickRange = range;
      fromDate = from;
      toDate = to;
    });
    fetchTransactions(searchByDate: true);
  }

  Widget _buildQuickRangeChips() {
    final scheme = Theme.of(context).colorScheme;
    final app = AppColors.of(context);
    const labels = <QuickRange, String>{
      QuickRange.today: 'Today',
      QuickRange.thisWeek: 'This week',
      QuickRange.thisMonth: 'This month',
      QuickRange.lastMonth: 'Last month',
      QuickRange.thisYear: 'This year',
      QuickRange.custom: 'Custom',
    };
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final entry in labels.entries)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(entry.value),
                avatar: entry.key == QuickRange.custom
                    ? Icon(Icons.date_range,
                        size: 16,
                        color: _quickRange == entry.key
                            ? scheme.primary
                            : app.textSecondary)
                    : null,
                selected: _quickRange == entry.key,
                showCheckmark: false,
                onSelected: (_) => _applyQuickRange(entry.key),
                selectedColor: scheme.primary.withValues(alpha: 0.18),
                backgroundColor: scheme.surface,
                shape: const StadiumBorder(),
                side: BorderSide(
                  color: _quickRange == entry.key
                      ? scheme.primary
                      : app.cardBorder,
                ),
                labelStyle: TextStyle(
                  fontSize: 13,
                  fontWeight: _quickRange == entry.key
                      ? FontWeight.w700
                      : FontWeight.w500,
                  color: _quickRange == entry.key
                      ? scheme.primary
                      : scheme.onSurface,
                ),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }

  Widget _typeFilterChip() {
    final scheme = Theme.of(context).colorScheme;
    final app = AppColors.of(context);
    final isIncome = _typeFilter == 'income';
    final color = isIncome ? app.income : app.expense;
    return InputChip(
      avatar: Icon(Icons.filter_alt, size: 16, color: color),
      label: Text(isIncome ? 'Income only' : 'Expenses only'),
      onDeleted: () => setState(() => _typeFilter = null),
      deleteIconColor: app.textSecondary,
      backgroundColor: color.withValues(alpha: 0.12),
      side: BorderSide(color: color.withValues(alpha: 0.5)),
      shape: const StadiumBorder(),
      labelStyle: TextStyle(
          fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurface),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _buildDateFilterArea() {
    final app = AppColors.of(context);

    // Preset ranges: one-line summary instead of the From/To fields.
    if (_quickRange != QuickRange.custom) {
      final from = _appliedFrom ?? fromDate;
      final to = _appliedTo ?? toDate;
      final sameDay =
          from.year == to.year && from.month == to.month && from.day == to.day;
      final rangeText = sameDay
          ? formatTransactionDate(from)
          : '${formatTransactionDate(from)} – ${formatTransactionDate(to)}';
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        runSpacing: 6,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.calendar_month_outlined,
                  size: 16, color: app.textSecondary),
              const SizedBox(width: 6),
              Text(rangeText,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: app.textSecondary)),
            ],
          ),
          if (_typeFilter != null) _typeFilterChip(),
        ],
      );
    }

    // Custom range: From / To fields + apply button.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 600;
            if (narrow) {
              return Column(
                children: [
                  Row(children: [
                    const SizedBox(
                        width: 42,
                        child: Text('From', style: TextStyle(fontSize: 12))),
                    Expanded(
                        child: _buildDateField(
                            date: fromDate,
                            onPressed: selectFromDate,
                            compact: true)),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    const SizedBox(
                        width: 42,
                        child: Text('To', style: TextStyle(fontSize: 12))),
                    Expanded(
                        child: _buildDateField(
                            date: toDate,
                            onPressed: selectToDate,
                            compact: true)),
                  ]),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => fetchTransactions(searchByDate: true),
                      icon: const Icon(Icons.filter_alt),
                      label: const Text('Apply date filter'),
                    ),
                  ),
                ],
              );
            }
            return Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: [
                const Text('From:'),
                _buildDateField(date: fromDate, onPressed: selectFromDate),
                const Text('To:'),
                _buildDateField(date: toDate, onPressed: selectToDate),
                ElevatedButton.icon(
                  onPressed: () => fetchTransactions(searchByDate: true),
                  icon: const Icon(Icons.search),
                  label: const Text('Search'),
                ),
              ],
            );
          },
        ),
        if (_typeFilter != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _typeFilterChip(),
          ),
      ],
    );
  }

  // --------------------------------------------------
  // TREND vs PREVIOUS PERIOD
  // --------------------------------------------------

  ({double income, double expense}) _totalsBetween(
      DateTime from, DateTime to) {
    final query = descriptionSearch.trim().toLowerCase();
    var income = 0.0;
    var expense = 0.0;
    for (final t in balanceTransactions) {
      final d = DateTime.tryParse(t['TranDate']?.toString() ?? '');
      if (d == null) continue;
      final day = DateTime(d.year, d.month, d.day);
      if (day.isBefore(from) || day.isAfter(to)) continue;
      if (query.isNotEmpty &&
          !(t['Description']?.toString().toLowerCase() ?? '')
              .contains(query)) {
        continue;
      }
      if (_isIncome(t)) {
        income += _amountOf(t);
      } else if (_isExpense(t)) {
        expense += _amountOf(t);
      }
    }
    return (income: income, expense: expense);
  }

  /// Totals for the period of equal length right before the applied range.
  ({double income, double expense})? get _previousTotals {
    final f = _appliedFrom;
    final t = _appliedTo;
    if (f == null || t == null) return null;
    final from = DateTime(f.year, f.month, f.day);
    final to = DateTime(t.year, t.month, t.day);
    if (from.isAfter(to)) return null;
    final days = DateTime.utc(to.year, to.month, to.day)
            .difference(DateTime.utc(from.year, from.month, from.day))
            .inDays +
        1;
    final prevTo = DateTime(from.year, from.month, from.day - 1);
    final prevFrom = DateTime(prevTo.year, prevTo.month, prevTo.day - (days - 1));
    return _totalsBetween(prevFrom, prevTo);
  }

  Widget? _trendChip({
    required double current,
    required double previous,
    required bool upIsGood,
    bool compact = false,
  }) {
    final app = AppColors.of(context);
    if (current.abs() < 0.005 && previous.abs() < 0.005) return null;
    final diff = current - previous;
    final flat = diff.abs() < 0.005;
    final up = diff > 0;
    final String label;
    if (flat) {
      label = '0%';
    } else if (previous.abs() < 0.005) {
      label = 'New';
    } else {
      final pct = (diff / previous.abs() * 100).abs();
      label = '${pct.toStringAsFixed(pct >= 100 ? 0 : 1)}%';
    }
    final color =
        flat ? app.textSecondary : (up == upIsGood ? app.income : app.expense);
    final icon = flat
        ? Icons.remove
        : (up ? Icons.arrow_upward : Icons.arrow_downward);
    return Tooltip(
      message: 'Compared with the previous period of the same length',
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: compact ? 10 : 12, color: color),
            const SizedBox(width: 2),
            Text(label,
                style: TextStyle(
                    fontSize: compact ? 9 : 11,
                    fontWeight: FontWeight.w700,
                    color: color)),
          ],
        ),
      ),
    );
  }

    // --------------------------------------------------
  // SUMMARY CARDS (count-up, tap = filter, long-press = breakdown)
  // --------------------------------------------------

  double get _cardElevation =>
      Theme.of(context).brightness == Brightness.dark ? 0.0 : 1.5;

  void _toggleTypeFilter(String type) {
    setState(() => _typeFilter = _typeFilter == type ? null : type);
  }

  Widget _buildSummaryRow() {
    final app = AppColors.of(context);
    final prev = _previousTotals;
    final income = totalIncome;
    final expenses = totalExpenses;
    final net = income - expenses;

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 600;
        final cardWidth = narrow ? (constraints.maxWidth - 12) / 3 : 240.0;
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _summaryCard(
                  'Income', income, Icons.trending_up, app.income,
                  width: cardWidth,
                  compact: narrow,
                  selected: _typeFilter == 'income',
                  onTap: () => _toggleTypeFilter('income'),
                  onLongPress: () => _showCardBreakdown('income'),
                  trend: prev == null
                      ? null
                      : _trendChip(
                          current: income,
                          previous: prev.income,
                          upIsGood: true,
                          compact: narrow),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _summaryCard(
                  'Expenses', expenses, Icons.trending_down, app.expense,
                  width: cardWidth,
                  compact: narrow,
                  selected: _typeFilter == 'expense',
                  onTap: () => _toggleTypeFilter('expense'),
                  onLongPress: () => _showCardBreakdown('expense'),
                  trend: prev == null
                      ? null
                      : _trendChip(
                          current: expenses,
                          previous: prev.expense,
                          upIsGood: false,
                          compact: narrow),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _summaryCard(
                  'Balance', net, Icons.account_balance_wallet_outlined,
                  app.accent,
                  width: cardWidth,
                  compact: narrow,
                  // Tapping Balance clears any Income/Expenses filter.
                  onTap: () => setState(() => _typeFilter = null),
                  onLongPress: () => _showCardBreakdown('balance'),
                  trend: prev == null
                      ? null
                      : _trendChip(
                          current: net,
                          previous: prev.income - prev.expense,
                          upIsGood: true,
                          compact: narrow),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _rangeLabel() {
    final from = _appliedFrom ?? fromDate;
    final to = _appliedTo ?? toDate;
    final sameDay =
        from.year == to.year && from.month == to.month && from.day == to.day;
    return sameDay
        ? formatTransactionDate(from)
        : '${formatTransactionDate(from)} – ${formatTransactionDate(to)}';
  }

  Widget _summaryCard(
    String title,
    double amount,
    IconData icon,
    Color accentColor, {
    double? width,
    bool compact = false,
    bool selected = false,
    Widget? trend,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final app = AppColors.of(context);
    final amountStyle = TextStyle(
      fontSize: compact ? 13 : 18,
      fontWeight: FontWeight.bold,
      color: scheme.onSurface,
    );
    return SizedBox(
      width: width ?? 240,
      child: Card(
        color: scheme.surface,
        elevation: _cardElevation,
        shadowColor: const Color(0x33885843),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? accentColor : app.cardBorder,
            width: selected ? 2 : 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: EdgeInsets.all(compact ? 7 : 18),
            child: compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [
                        Icon(icon, color: accentColor, size: 14),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 10,
                                color: app.textSecondary,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (selected)
                          Icon(Icons.filter_alt, size: 12, color: accentColor),
                      ]),
                      const SizedBox(height: 5),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: CountUpAmount(
                          value: amount,
                          hidden: _hideAmounts,
                          style: amountStyle,
                        ),
                      ),
                      if (trend != null) ...[
                        const SizedBox(height: 5),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: trend,
                        ),
                      ],
                    ],
                  )
                : Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Icon(icon, color: accentColor, size: 25),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(children: [
                              Expanded(
                                child: Text(title,
                                    style: TextStyle(
                                        fontSize: 13,
                                        color: app.textSecondary,
                                        fontWeight: FontWeight.w500)),
                              ),
                              if (selected)
                                Icon(Icons.filter_alt,
                                    size: 16, color: accentColor),
                            ]),
                            const SizedBox(height: 8),
                            CountUpAmount(
                              value: amount,
                              hidden: _hideAmounts,
                              style: amountStyle,
                            ),
                            if (trend != null) ...[
                              const SizedBox(height: 8),
                              trend,
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------
  // COLLAPSIBLE FILTER AREA
  // --------------------------------------------------

  Widget _buildFilterSection() {
    final app = AppColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _filtersCollapsed
                  ? Row(
                      children: [
                        Icon(Icons.calendar_month_outlined,
                            size: 16, color: app.textSecondary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _typeFilter == null
                                ? _rangeLabel()
                                : '${_rangeLabel()} · ${_typeFilter == 'income' ? 'Income only' : 'Expenses only'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: app.textSecondary),
                          ),
                        ),
                      ],
                    )
                  : _buildQuickRangeChips(),
            ),
            IconButton(
              tooltip: _filtersCollapsed ? 'Show filters' : 'Hide filters',
              visualDensity: VisualDensity.compact,
              onPressed: () =>
                  setState(() => _filtersCollapsed = !_filtersCollapsed),
              icon: Icon(
                _filtersCollapsed ? Icons.expand_more : Icons.expand_less,
                color: app.textSecondary,
              ),
            ),
          ],
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _filtersCollapsed
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildDateFilterArea(),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  // --------------------------------------------------
  // LONG-PRESS BREAKDOWN (top categories)
  // --------------------------------------------------

  Future<void> _showCardBreakdown(String kind) async {
    final scheme = Theme.of(context).colorScheme;
    final app = AppColors.of(context);

    final income = totalIncome;
    final expenses = totalExpenses;
    final net = income - expenses;

    final isIncomeKind = kind == 'income';
    final isBalanceKind = kind == 'balance';
    final accent =
        isIncomeKind ? app.income : (isBalanceKind ? app.accent : app.expense);
    final title = isIncomeKind
        ? 'Income breakdown'
        : (isBalanceKind ? 'Balance overview' : 'Expense breakdown');
    final headline = isIncomeKind ? income : (isBalanceKind ? net : expenses);
    final listTitle = isIncomeKind ? 'Top income categories' : 'Top spending categories';

    // Income card -> income rows. Expenses / Balance -> expense rows.
    final rows = filteredTransactions.where(isIncomeKind ? _isIncome : _isExpense);
    final totals = <String, double>{};
    for (final t in rows) {
      final name = (t['CategoryName'] ?? '').toString().trim();
      final key = name.isEmpty ? 'Uncategorized' : name;
      totals[key] = (totals[key] ?? 0) + _amountOf(t);
    }
    final sorted = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final listTotal = totals.values.fold(0.0, (a, b) => a + b);
    const maxRows = 5;
    final top = sorted.take(maxRows).toList();
    final othersValue = sorted.skip(maxRows).fold(0.0, (a, e) => a + e.value);
    final entries = <MapEntry<String, double>>[
      ...top,
      if (othersValue > 0) MapEntry('Others', othersValue),
    ];

    final from = _appliedFrom ?? fromDate;
    final to = _appliedTo ?? toDate;
    final sameDay =
        from.year == to.year && from.month == to.month && from.day == to.day;
    final period = sameDay
        ? formatTransactionDate(from)
        : '${formatTransactionDate(from)} – ${formatTransactionDate(to)}';

    Widget statLine(String label, double value, Color color) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                  child: Text(label,
                      style: TextStyle(color: app.textSecondary))),
              Text(_displayAmount(value),
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: color)),
            ],
          ),
        );

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(period,
                  style: TextStyle(fontSize: 12, color: app.textSecondary)),
              const SizedBox(height: 10),
              Text(_displayAmount(headline),
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: accent)),
              if (isBalanceKind) ...[
                const SizedBox(height: 10),
                statLine('Income', income, app.income),
                statLine('Expenses', expenses, app.expense),
                if (income > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                            child: Text('Saved from income',
                                style: TextStyle(color: app.textSecondary))),
                        Text(
                          '${(net / income * 100).toStringAsFixed(1)}%',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: net >= 0 ? app.income : app.expense),
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              Text(listTitle,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              if (filteredTransactions.isEmpty || entries.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    filteredTransactions.isEmpty
                        ? 'No transactions in this period.'
                        : (isIncomeKind
                            ? 'No income transactions in this period.'
                            : 'No expense transactions in this period.'),
                    style: TextStyle(color: app.textSecondary),
                  ),
                )
              else
                for (final e in entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(e.key,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 8),
                            Text(_displayAmount(e.value),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 44,
                              child: Text(
                                '${(listTotal <= 0 ? 0 : e.value / listTotal * 100).toStringAsFixed(0)}%',
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                    fontSize: 12, color: app.textSecondary),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: listTotal <= 0 ? 0 : e.value / listTotal,
                            minHeight: 6,
                            color: accent,
                            backgroundColor: accent.withValues(alpha: 0.12),
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------
  // MOBILE: CARD-STYLE ROWS WITH SWIPE ACTIONS
  // --------------------------------------------------

  Widget _buildEmptyState() {
    final app = AppColors.of(context);
    final filtered = _typeFilter != null ||
        descriptionSearch.trim().isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined,
                size: 56, color: app.textSecondary.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            const Text('No transactions found',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              filtered
                  ? 'Try changing the date range or filters.'
                  : 'Add a new transaction to get started.',
              textAlign: TextAlign.center,
              style: TextStyle(color: app.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileList(
      List<Map<String, dynamic>> items, Map<String, double> balances) {
    if (items.isEmpty) {
      if (_loading) return const _SkeletonList();
      return RefreshIndicator(
        onRefresh: _reload,
        child: LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: SizedBox(height: c.maxHeight, child: _buildEmptyState()),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        controller: _listController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final t = items[index];
          return Padding(
            key: ValueKey('row_${t['id']}'),
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildTransactionCard(t, balances),
          );
        },
      ),
    );
  }

  Widget _swipeBackground({
    required Alignment alignment,
    required Color color,
    required Color foreground,
    required IconData icon,
    required String label,
  }) {
    return Container(
      alignment: alignment,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: foreground),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  color: foreground,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// Copies a transaction as a NEW one dated today. Description, amount, type,
  /// mode, category, remarks and other are copied; images are not.
  Future<void> _repeatTransaction(Map<String, dynamic> t) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    String? textOrNull(String key) {
      final v = (t[key] ?? '').toString().trim();
      return v.isEmpty ? null : v;
    }

    final description = (t['Description'] ?? '').toString().trim();
    final category = (t['CategoryName'] ?? '').toString().trim();
    final amount = _amountOf(t);
    final label = description.isNotEmpty
        ? description
        : (category.isNotEmpty ? category : 'Transaction');

    final int newId;
    try {
      newId = await LocalTransactionDatabase.instance.insert(<String, dynamic>{
        'TranDate':
            '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}',
        'Description': t['Description'],
        'Amount': amount,
        'Type': t['Type'],
        'Mode': t['Mode'],
        'Remarks': textOrNull('Remarks'),
        'Other': textOrNull('Other'),
        'CategoryName': t['CategoryName'],
        'CreationDate': now.toIso8601String(),
        'IsDeleted': 0,
        'Image1Path': null,
        'Image2Path': null,
        'Image1Blob': null,
        'Image2Blob': null,
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not repeat: $e')));
      return;
    }

    // If a preset range (Today / This week / ...) was loaded before today
    // (app left open overnight), roll it forward so the new row is visible.
    final appliedTo = _appliedTo;
    final presetEndsAtToday = _quickRange == QuickRange.today ||
        _quickRange == QuickRange.thisWeek ||
        _quickRange == QuickRange.thisMonth ||
        _quickRange == QuickRange.thisYear;
    final stale = appliedTo != null &&
        today.isAfter(DateTime(appliedTo.year, appliedTo.month, appliedTo.day));
    final rolledForward = stale && presetEndsAtToday;
    if (rolledForward) {
      _applyQuickRange(_quickRange);
    } else {
      await _reload();
    }
    if (!mounted) return;

    final f = _appliedFrom;
    final to = _appliedTo;
    final visible = rolledForward ||
        f == null ||
        to == null ||
        (!today.isBefore(DateTime(f.year, f.month, f.day)) &&
            !today.isAfter(DateTime(to.year, to.month, to.day)));

    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 5),
      content: Text(
        'Added “$label” · ${_displayAmount(amount)} for today'
        '${visible ? '' : ' (hidden by the current date filter)'}',
      ),
      action: SnackBarAction(
        label: 'UNDO',
        onPressed: () async {
          try {
            await LocalTransactionDatabase.instance.softDelete(newId);
          } catch (e) {
            debugPrint('Undo repeat failed: $e');
          }
          await _reload();
        },
      ),
    ));
  }

  Widget _buildTransactionCard(
      Map<String, dynamic> t, Map<String, double> balances) {
    final scheme = Theme.of(context).colorScheme;
    final app = AppColors.of(context);
    final id = t['id'].toString();
    final isIncome = _isIncome(t);
    final isExpense = _isExpense(t);
    final color =
        isIncome ? app.income : (isExpense ? app.expense : app.textSecondary);
    final sign = isIncome ? '+' : (isExpense ? '−' : '');
    final description = (t['Description'] ?? '').toString().trim();
    final category = (t['CategoryName'] ?? '').toString().trim();
    final mode = (t['Mode'] ?? '').toString().trim();
    final date = DateTime.tryParse(t['TranDate']?.toString() ?? '');
    final subtitle = [
      if (category.isNotEmpty) category,
      if (mode.isNotEmpty) mode,
      if (date != null) formatTransactionDate(date),
    ].join(' · ');

    return Dismissible(
      key: ValueKey('txn_$id'),
      direction: DismissDirection.horizontal,
      background: _swipeBackground(
        alignment: Alignment.centerLeft,
        color: app.accent,
        foreground: scheme.onSecondary,
        icon: Icons.edit_outlined,
        label: 'Edit',
      ),
      secondaryBackground: _swipeBackground(
        alignment: Alignment.centerRight,
        color: scheme.primary,
        foreground: scheme.onPrimary,
        icon: Icons.repeat,
        label: 'Repeat',
      ),
      // Swipe right: open the editor. Swipe left: repeat for today (with
      // UNDO). The card always snaps back; delete is in the details sheet.
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          openEditTransaction(t);
        } else {
          _repeatTransaction(t);
        }
        return false;
      },
      child: Card(
        color: scheme.surface,
        elevation: _cardElevation,
        shadowColor: const Color(0x33885843),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: app.cardBorder),
        ),
        child: InkWell(
          onTap: () => _showTransactionDetails(t, balances),
          onLongPress: () => _repeatTransaction(t),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    isIncome ? Icons.south_west : Icons.north_east,
                    color: color,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        description.isEmpty
                            ? (category.isEmpty ? 'Transaction' : category)
                            : description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 12, color: app.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_transactionHasImages(t))
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: Icon(Icons.image_outlined,
                                size: 14, color: app.textSecondary),
                          ),
                        Text(
                          '$sign${_displayAmount(_amountOf(t))}',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: color),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Bal ${_displayAmount(balances[id] ?? 0.0)}',
                      style: TextStyle(fontSize: 11, color: app.textSecondary),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showTransactionDetails(
      Map<String, dynamic> t, Map<String, double> balances) async {
    final scheme = Theme.of(context).colorScheme;
    final app = AppColors.of(context);
    final id = t['id'].toString();
    final isIncome = _isIncome(t);
    final isExpense = _isExpense(t);
    final color =
        isIncome ? app.income : (isExpense ? app.expense : app.textSecondary);
    final sign = isIncome ? '+' : (isExpense ? '−' : '');
    final date = DateTime.tryParse(t['TranDate']?.toString() ?? '');
    String clean(String key) => (t[key] ?? '').toString().trim();
    final title = clean('Description').isEmpty
        ? 'Transaction #$id'
        : clean('Description');

    final rows = <MapEntry<String, String>>[
      MapEntry('Transaction No.', id),
      if (date != null) MapEntry('Date', formatTransactionDate(date)),
      MapEntry('Type', clean('Type')),
      MapEntry('Mode', clean('Mode')),
      MapEntry('Category', clean('CategoryName')),
      MapEntry('Remarks', clean('Remarks')),
      MapEntry('Other', clean('Other')),
      MapEntry('Balance after', _displayAmount(balances[id] ?? 0.0)),
    ].where((e) => e.value.isNotEmpty).toList();

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: scheme.surface,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(
                '$sign${_displayAmount(_amountOf(t))}',
                style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.bold, color: color),
              ),
              const SizedBox(height: 14),
              for (final row in rows)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 120,
                        child: Text(row.key,
                            style: TextStyle(color: app.textSecondary)),
                      ),
                      Expanded(
                        child: Text(row.value,
                            style:
                                const TextStyle(fontWeight: FontWeight.w500)),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.pop(sheetContext);
                    _repeatTransaction(t);
                  },
                  icon: const Icon(Icons.repeat, size: 18),
                  label: const Text('Repeat for today'),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        openEditTransaction(t);
                      },
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('Edit'),
                    ),
                  ),
                  if (_transactionHasImages(t)) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.pop(sheetContext);
                          _showTransactionImages(t);
                        },
                        icon: const Icon(Icons.image_outlined, size: 18),
                        label: const Text('Images'),
                      ),
                    ),
                  ],
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: app.expense,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        deleteTransaction(int.parse(id));
                      },
                      icon: const Icon(Icons.delete_outline, size: 18),
                      label: const Text('Delete'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --------------------------------------------------
  // BUILD MAIN SCREEN
  // --------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final balances = runningBalances;
    
final sortedTransactions =
      List<Map<String, dynamic>>.from(visibleTransactions);

  sortedTransactions.sort((a, b) {
    final dateA =
        DateTime.tryParse(a['TranDate']?.toString() ?? '') ??
            DateTime(2000);
    final dateB =
        DateTime.tryParse(b['TranDate']?.toString() ?? '') ??
            DateTime(2000);

    final dateComparison = dateB.compareTo(dateA);
    if (dateComparison != 0) return dateComparison;

    // For the same date, show the higher transaction ID first
    final idA = int.tryParse(a['id']?.toString() ?? '') ?? 0;
    final idB = int.tryParse(b['id']?.toString() ?? '') ?? 0;
    return idB.compareTo(idA);
  });

    return Scaffold(
      /*appBar: AppBar(
        title: const Row(
          children: [
            Image(
              image: AssetImage('assets/icon/DayToDay_Logo.png'),
              width: 30,
              height: 30,
            ),
            SizedBox(width: 10),
            Text(
              'Day To Day',
              style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: -0.4),
            ),
            Text(
                '  Spend Smart. Live Better!',
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFF877C74)),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Exit application',
            icon: const Icon(Icons.power_settings_new,
                color: Color(0xFFEF4444), size: 28),
            onPressed: () async {
              final shouldExit = await showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Exit Day To Day?'),
                  content: const Text(
                      'Are you sure you want to close the application?'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Color(0xFFEF4444)),
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Exit'),
                    ),
                  ],
                ),
              );
              if (shouldExit == true) SystemNavigator.pop();
            },
          ),
          const SizedBox(width: 8),
        ],
      ),*/
      
      
appBar: AppBar(
  toolbarHeight: 64,
  titleSpacing: 4,
  leading: Builder(
    builder: (ctx) => IconButton(
      tooltip: 'Menu',
      icon: const Icon(Icons.menu, size: 28),
      onPressed: () => Scaffold.of(ctx).openDrawer(),
    ),
  ),
  title: Row(
    children: [
      Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Day To Day',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.bold,
                letterSpacing: -0.4,
                height: 1.0,
              ),
            ),
            SizedBox(height: 3),
            Text(
              'Spend Smart. Live Better!',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.of(context).textSecondary,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    ],
  ),
  actions: [
    IconButton(
      tooltip: _hideAmounts ? 'Show amounts' : 'Hide amounts',
      onPressed: () => setState(() => _hideAmounts = !_hideAmounts),
      icon: Icon(
        _hideAmounts
            ? Icons.visibility_off_outlined
            : Icons.visibility_outlined,
        size: 24,
      ),
    ),
    ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return IconButton(
          tooltip: isDark ? 'Switch to light theme' : 'Switch to dark theme',
          onPressed: () =>
              setThemeMode(isDark ? ThemeMode.light : ThemeMode.dark),
          icon: Icon(
            isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            size: 26,
            color: Theme.of(context).colorScheme.primary,
          ),
        );
      },
    ),
    IconButton(
      tooltip: 'Exit application',
      icon: const Icon(
        Icons.power_settings_new,
        color: Color(0xFFEF4444),
        size: 28,
      ),
      onPressed: () async {
        final shouldExit = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Exit Day To Day?'),
            content: const Text(
              'Are you sure you want to close the application?',
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Color(0xFFEF4444),
                ),
                onPressed: () =>
                    Navigator.pop(dialogContext, true),
                child: const Text('Exit'),
              ),
            ],
          ),
        );

        if (shouldExit == true) {
          SystemNavigator.pop();
        }
      },
    ),
    const SizedBox(width: 8),
  ],
),

      
      drawer: _buildDrawer(),
      floatingActionButton:
          (MediaQuery.sizeOf(context).width < 600)
              ? AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: animation,
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: _fabExtended
                      ? FloatingActionButton.extended(
                          key: const ValueKey('fab_extended'),
                          heroTag: null,
                          onPressed: openNewTransaction,
                          icon: const Icon(Icons.add),
                          label: const Text('New'),
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Theme.of(context).colorScheme.onPrimary,
                        )
                      : FloatingActionButton(
                          key: const ValueKey('fab_mini'),
                          heroTag: null,
                          tooltip: 'New transaction',
                          onPressed: openNewTransaction,
                          backgroundColor: Theme.of(context).colorScheme.primary,
                          foregroundColor: Theme.of(context).colorScheme.onPrimary,
                          child: const Icon(Icons.add),
                        ),
                )
              : null,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ------------------------------------------
            // NEW button (wide screens; phones use the floating button)
            // ------------------------------------------
            if (MediaQuery.sizeOf(context).width >= 600) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  ),
                  onPressed: openNewTransaction,
                  icon: const Icon(Icons.add),
                  label: const Text('New'),
                ),
              ),
              const SizedBox(height: 12),
            ],

            // ------------------------------------------
            // INCOME / EXPENSE / BALANCE SUMMARY
            // ------------------------------------------
            _buildSummaryRow(),

            const SizedBox(height: 12),

            // ------------------------------------------
            // QUICK DATE CHIPS (+ custom range fields)
            // ------------------------------------------
            _buildFilterSection(),

            const SizedBox(height: 12),

            // Search only within the Description column.
            TextField(
              controller: descriptionSearchController,
              onChanged: (value) => setState(() => descriptionSearch = value),
              decoration: InputDecoration(
                //hintText: 'Filter by description...',
                hintText: 'Search by description...',
                hintStyle: const TextStyle(
                     fontStyle: FontStyle.italic,
                  ),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: descriptionSearch.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear description filter',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          descriptionSearchController.clear();
                          setState(() => descriptionSearch = '');
                        },
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),

            const SizedBox(height: 8),

            // ------------------------------------------
// FIXED HEADER + SCROLLABLE TRANSACTION TABLE
// ------------------------------------------
Expanded(
  child: LayoutBuilder(
    builder: (context, constraints) {
    // Phones: card-style rows with swipe actions. Wide screens: the table.
    if (constraints.maxWidth < 600) {
      return _buildMobileList(sortedTransactions, balances);
    }
    final columnWidths = <int, TableColumnWidth>{
      for (int i = 0; i < 11; i++)
        i: FixedColumnWidth(_columnWidth(i)),
    };

    final headers = <String>[
      'Transaction No.',
      'Transaction Date',
      'Description',
      'Amount',
      'Type',
      'Mode',
      'Remarks',
      'Other',
      'CategoryName',
      'Balance',
      'Actions',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // FIXED HEADER: does not scroll vertically
        SingleChildScrollView(
          controller: _headerHorizontalController,
          scrollDirection: Axis.horizontal,
          child: Table(
            //defaultColumnWidth: const IntrinsicColumnWidth(),
            defaultColumnWidth: const FixedColumnWidth(120),
            columnWidths: columnWidths,
            border: TableBorder(
              horizontalInside: BorderSide(color: AppColors.of(context).cardBorder),
            ),
            children: [
              TableRow(
                decoration: BoxDecoration(color: AppColors.of(context).tableHeader),
                children: List.generate(
                  headers.length,
                  (index) => _headerCell(headers[index], index),
                ),
              ),
            ],
          ),
        ),

        // TRANSACTION BODY: scrolls vertically and horizontally
        Expanded(
          child: sortedTransactions.isEmpty
              ? (_loading ? const _SkeletonList() : _buildEmptyState())
              : SingleChildScrollView(
            controller: _bodyHorizontalController,
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              child: Table(
                // defaultColumnWidth: const IntrinsicColumnWidth(),
                defaultColumnWidth: const FixedColumnWidth(120),
                columnWidths: columnWidths,
                border: TableBorder(
              horizontalInside: BorderSide(color: AppColors.of(context).cardBorder),
            ),
                children: sortedTransactions.map((transaction) {
                  final id = transaction['id'].toString();

                  return TableRow(
                    children: [
                      // 0: Transaction No.
                      _bodyText(id, 0),

                      // 1: Transaction Date
                      _bodyText(
                        formatTransactionDate(
                          DateTime.parse(
                            transaction['TranDate'].toString(),
                          ),
                        ),
                        1,
                      ),

                      // 2: Description
                      _bodyText(
                        transaction['Description']?.toString() ?? '',
                        2,
                      ),

                      // 3: Amount
                      _bodyText(
                        _hideAmounts
                            ? '₹ ••••'
                            : transaction['Amount'].toString(),
                        3,
                      ),

                      // 4: Type
                      _bodyText(
                        transaction['Type']?.toString() ?? '',
                        4,
                      ),

                      // 5: Mode
                      _bodyText(
                        transaction['Mode']?.toString() ?? '',
                        5,
                      ),

                      // 6: Remarks
                      _bodyText(
                        transaction['Remarks']?.toString() ?? '',
                        6,
                      ),

                      // 7: Other
                      _bodyText(
                        transaction['Other']?.toString() ?? '',
                        7,
                      ),

                      // 8: CategoryName
                      _bodyText(
                        transaction['CategoryName']?.toString() ?? '',
                        8,
                      ),

                      // 9: Balance
                      _bodyText(
                        _displayAmount(balances[id] ?? 0.0),
                        9,
                      ),

                      // 10: Actions
                      _bodyCell(
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Repeat for today',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 40,
                                height: 40,
                              ),
                              icon: Icon(
                                Icons.repeat,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              onPressed: () => _repeatTransaction(transaction),
                            ),
                            IconButton(
                              tooltip: 'Delete transaction',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 40,
                                height: 40,
                              ),
                              icon: Icon(
                                Icons.delete_outline,
                                color: AppColors.of(context).expense,
                              ),
                              onPressed: () {
                                final transactionId = int.parse(id);
                                deleteTransaction(transactionId);
                              },
                            ),
                            IconButton(
                              tooltip: 'Edit transaction',
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 40,
                                height: 40,
                              ),
                              icon: Icon(
                                Icons.edit_outlined,
                                color: AppColors.of(context).accent,
                              ),
                              onPressed: () {
                                openEditTransaction(transaction);
                              },
                            ),
                            if (_transactionHasImages(transaction))
                              IconButton(
                                tooltip: 'View transaction images',
                                visualDensity: VisualDensity.compact,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints.tightFor(
                                  width: 40,
                                  height: 40,
                                ),
                                icon: Icon(
                                  Icons.image_outlined,
                                  color: AppColors.of(context).textSecondary,
                                ),
                                onPressed: () {
                                  _showTransactionImages(transaction);
                                },
                              ),
                          ],
                        ),
                        10,
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ],
    );
  },
),
),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------
  // SIDE DRAWER (Backup + About)
  // --------------------------------------------------

  Widget _buildDrawer() {
    final scheme = Theme.of(context).colorScheme;
    final app = AppColors.of(context);
    return Drawer(
      backgroundColor: scheme.surface,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Day To Day',
                      style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.4)),
                  const SizedBox(height: 4),
                  Text('Spend Smart. Live Better!',
                      style:
                          TextStyle(fontSize: 12, color: app.textSecondary)),
                ],
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.file_download_outlined,
                  color: scheme.primary),
              title: const Text('Backup'),
              onTap: () {
                Navigator.pop(context); // close the drawer
                exportTransactionsToExcel();
              },
            ),
            ListTile(
              leading: Icon(Icons.info_outline, color: scheme.primary),
              title: const Text('About'),
              onTap: () {
                Navigator.pop(context); // close the drawer
                _showAboutDialog();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAboutDialog() {
    final app = AppColors.of(context);
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Image(
              image: AssetImage('assets/icon/DayToDay_Logo_brown.png'),
              width: 88,
              height: 88,
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 14),
            const Text('Day To Day',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('v$kAppVersion',
                style: TextStyle(fontSize: 14, color: app.textSecondary)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            style: TextButton.styleFrom(
              backgroundColor: Color(0xFFEF4444),
              foregroundColor: Colors.white,
            ),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // --------------------------------------------------
  // DATE FIELD
  // --------------------------------------------------

  Widget _buildDateField({
    required DateTime date,
    required VoidCallback onPressed,
    bool compact = false,
  }) {
    return SizedBox(
      width: compact ? null : 185,
      child: InkWell(
        onTap: onPressed,
        child: InputDecorator(
          decoration: InputDecoration(
            isDense: compact,
            contentPadding: EdgeInsets.symmetric(
                horizontal: 10, vertical: compact ? 10 : 14),
            border: const OutlineInputBorder(),
            suffixIcon: const Icon(Icons.calendar_today, size: 18),
          ),
          child: Text(formatDate(date)),
        ),
      ),
    );
  }

  // --------------------------------------------------
  // IMAGES
  // --------------------------------------------------

  bool _transactionHasImages(Map<String, dynamic> t) =>
      t['HasImage1'] == 1 || t['HasImage2'] == 1;

  Future<void> _showTransactionImages(Map<String, dynamic> transaction) async {
    final row = await LocalTransactionDatabase.instance
        .getImages(int.parse(transaction['id'].toString()));
    if (row == null || !mounted) return;
    final images = <Uint8List>[];
    for (final key in ['Image1Blob', 'Image2Blob']) {
      final b = row[key];
      if (b is Uint8List && b.isNotEmpty) images.add(b);
    }
    if (images.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        /*title: Text('Image Viewer • Txn #${transaction['id']}',
                 style: const TextStyle(fontWeight: FontWeight.w600)),*/
        title: Row(
              children: [
                Expanded(
                  child: Text(
                    'Image Viewer    Txn #${transaction['id']}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton.filled(
                  //tooltip: 'Close image',
                  style: IconButton.styleFrom(
                    backgroundColor: Color(0xFFEF4444),
                    foregroundColor: Colors.white,
                ),
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < images.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: InkWell(
                      onTap: () => showDialog<void>(
                        context: dialogContext,
                        builder: (imageContext) => Dialog.fullscreen(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: InteractiveViewer(
                                  minScale: 0.5,
                                  maxScale: 5,
                                  child: Center(
                                    child: Image.memory(images[i],
                                        fit: BoxFit.contain),
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 24,
                                right: 12,
                                child: 
                                IconButton.filled(
                                  //tooltip: 'Close image',
                                  style: IconButton.styleFrom(
                                    backgroundColor: Color(0xFFEF4444),
                                    foregroundColor: Colors.white,
                                  ),
                                  onPressed: () => Navigator.pop(imageContext),
                                  icon: const Icon(Icons.close),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Image ${i + 1}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(images[i],
                                height: 190,
                                width: double.infinity,
                                fit: BoxFit.contain),
                          ),
                          Text('Tap to enlarge',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.of(context).textSecondary)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        
      ),
    );
  }

  // --------------------------------------------------
  // EXCEL BACKUP
  // --------------------------------------------------

  Future<void> exportTransactionsToExcel() async {
    try {
      // Full record: includes soft-deleted rows (flagged in the IsDeleted column).
      final rows = await LocalTransactionDatabase.instance
          .getTransactions(includeDeleted: true);

      final book = Excel.createExcel();
      final defaultName = book.getDefaultSheet();
      if (defaultName != null) book.rename(defaultName, 'Transactions');
      final sheet = book['Transactions'];

      sheet.appendRow([
        TextCellValue('id'), TextCellValue('TranDate'),
        TextCellValue('Description'), TextCellValue('Amount'),
        TextCellValue('Type'), TextCellValue('Mode'),
        TextCellValue('Remarks'), TextCellValue('Other'),
        TextCellValue('CategoryName'), TextCellValue('CreationDate'),
        TextCellValue('IsDeleted'),
      ]);

      final dateFormatter = DateFormat('dd-MM-yyyy HH:mm:ss');
      for (final r in rows) {
        final d = DateTime.tryParse(r['CreationDate']?.toString() ?? '');
        final created = d == null ? '' : '${dateFormatter.format(d)} IST';
        sheet.appendRow([
          IntCellValue((r['id'] as num).toInt()),
          TextCellValue('${r['TranDate']}'),
          TextCellValue('${r['Description']}'),
          DoubleCellValue((r['Amount'] as num).toDouble()),
          TextCellValue('${r['Type']}'),
          TextCellValue('${r['Mode']}'),
          TextCellValue('${r['Remarks'] ?? ''}'),
          TextCellValue('${r['Other'] ?? ''}'),
          TextCellValue('${r['CategoryName'] ?? ''}'),
          TextCellValue(created),
          BoolCellValue(((r['IsDeleted'] as num?)?.toInt() ?? 0) == 1),
        ]);
      }

      final bytes = book.encode();
      if (bytes == null) throw Exception('Could not generate Excel file');

      final now = DateTime.now();
      final filenameFormatter = DateFormat('yyyy-MM-dd_HH-mm-ss');
      final filename = 'Transactions_backup_${filenameFormatter.format(now)}';

      final uri = await FileSaver.instance.saveToDownloads(
        name: filename,
        bytes: Uint8List.fromList(bytes),
        fileExtension: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );

      if (!mounted) return;
      if (uri != null && uri.isNotEmpty) await showBackupNotification(uri);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(uri != null && uri.isNotEmpty
            ? 'Local Excel backup downloaded: $filename.xlsx'
            : 'Backup created, but saved location could not be confirmed.'),
      ));
    } catch (e, st) {
      debugPrint('LOCAL EXPORT ERROR: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Excel export failed: $e')));
    }
  }

  // --------------------------------------------------
  // DELETE (soft delete)
  // --------------------------------------------------

  Future<void> deleteTransaction(int id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete transaction #$id .'),
        content: Text('Are you sure you want to delete this record ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          /*FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),*/
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Color(0xFFEF4444),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      await LocalTransactionDatabase.instance.softDelete(id);
      await _reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Transaction #$id deleted')));
    } catch (e, st) {
      debugPrint('LOCAL DELETE ERROR: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete transaction: $e')));
    }
  }
}

// --------------------------------------------------
// ADD / EDIT TRANSACTION PAGE
// --------------------------------------------------

class AddExpensePage extends StatefulWidget {
  final Map<String, dynamic>? transaction;

  const AddExpensePage({
    super.key,
    this.transaction,
  });

  @override
  State<AddExpensePage> createState() => _AddExpensePageState();
}

class _AddExpensePageState extends State<AddExpensePage> {
  bool isSaving = false;
  bool imagesLoading = false;

  // -----------------------------
  // Images (kept in memory as bytes; stored in SQLite as BLOBs)
  // -----------------------------
  final ImagePicker _imagePicker = ImagePicker();
  Uint8List? image1Bytes;
  Uint8List? image2Bytes;

  Future<void> _pickTransactionImage(int slot) async {
    try {
      final picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (picked == null || !mounted) return;

      // Compress into a temp file, read the bytes, then delete the temp file
      // (the image itself lives in the database).
      final tempDir = await getTemporaryDirectory();
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final targetPath =
          p.join(tempDir.path, 'transaction_${stamp}_$slot.jpg');

      final compressed = await FlutterImageCompress.compressAndGetFile(
        picked.path,
        targetPath,
        minWidth: 1280,
        minHeight: 1280,
        quality: 75,
        format: CompressFormat.jpeg,
        keepExif: false,
      );

      if (compressed == null) {
        throw Exception('Image compression failed');
      }

      final bytes = await File(compressed.path).readAsBytes();

      try {
        await File(compressed.path).delete();
      } catch (_) {
        // Temp file cleanup is best-effort.
      }

      if (!mounted) return;
      setState(() {
        if (slot == 1) {
          image1Bytes = bytes;
        } else {
          image2Bytes = bytes;
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not attach image: $e')),
      );
    }
  }

  void _removeTransactionImage(int slot) {
    setState(() {
      if (slot == 1) {
        image1Bytes = null;
      } else {
        image2Bytes = null;
      }
    });
  }

  Widget _buildImageAttachmentCard(
      {required int slot, required Uint8List? bytes}) {
    final exists = bytes != null && bytes.isNotEmpty;
    return Expanded(
      child: InkWell(
        onTap: () => _pickTransactionImage(slot),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 120),
          padding: const EdgeInsets.all(10),
          decoration: flutter.BoxDecoration(
            border: flutter.Border.all(color: Theme.of(context).dividerColor),
            borderRadius: flutter.BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (exists)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(bytes,
                      height: 90, width: double.infinity, fit: BoxFit.cover),
                )
              else
                const Icon(Icons.add_photo_alternate_outlined, size: 38),
              const SizedBox(height: 8),
              Text(exists ? 'Image $slot • Tap to change' : 'Add image $slot',
                  textAlign: TextAlign.center),
              if (exists)
                TextButton.icon(
                  onPressed: () => _removeTransactionImage(slot),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('Remove'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _applyDefaults() {
    selectedCategory = 'Other';
    selectedMode = 'UPI';
    selectedType = 'Expense';
  }

  // -----------------------------
  // Controllers
  // -----------------------------

  final TextEditingController amountController = TextEditingController();
  final TextEditingController otherController = TextEditingController();
  final TextEditingController remarksController = TextEditingController();
  final TextEditingController descriptionController = TextEditingController();

  // -----------------------------
  // Dropdown values
  // -----------------------------

  String? selectedCategory;
  String? selectedMode;
  String? selectedType;

  final List<String> categories = [
    'Other',
    'Books',
    'Cash Given',
    'Clothes',
    'Cosmetic',
    'Dairy',
    'Food',
    'Fruits',
    'Fuel',
    'Grocery',
    'Internet/Wi-Fi',
    'Medicine',
    'Mobile Recharge',
    'Shoes',
    'Stationery',
    'Travel',
    'Vegetables',
  ];

  final List<String> modes = ['UPI', 'Cash', 'Card'];

  final List<String> types = ['Expense', 'Income'];

  // -----------------------------
  // Dates
  // -----------------------------

  DateTime transactionDate = DateTime.now();

  bool get isEditing => widget.transaction != null;

  @override
  void initState() {
    super.initState();
    if (isEditing) {
      _loadTransactionIntoForm();
    } else {
      _applyDefaults(); // defaults only for new transactions
    }
  }

  Uint8List? _bytesFromDb(dynamic value) {
    if (value is Uint8List && value.isNotEmpty) return value;
    if (value is List<int> && value.isNotEmpty) return Uint8List.fromList(value);
    return null;
  }

  // The list query does not include image BLOBs, so load them for this row.
  // Save stays disabled until this finishes, so images can never be overwritten with null.
  Future<void> _loadExistingImages() async {
    imagesLoading = true;
    try {
      final id = (widget.transaction!['id'] as num).toInt();
      final row = await LocalTransactionDatabase.instance.getImages(id);
      if (!mounted) return;
      setState(() {
        image1Bytes ??= _bytesFromDb(row?['Image1Blob']);
        image2Bytes ??= _bytesFromDb(row?['Image2Blob']);
      });
    } catch (e, st) {
      debugPrint('LOAD IMAGES ERROR: $e');
      debugPrintStack(stackTrace: st);
    } finally {
      if (mounted) setState(() => imagesLoading = false);
    }
  }

  void _loadTransactionIntoForm() {
    final transaction = widget.transaction;
    if (transaction == null) return;

    transactionDate = DateTime.parse(transaction['TranDate'].toString());
    descriptionController.text = transaction['Description']?.toString() ?? '';
    amountController.text = transaction['Amount']?.toString() ?? '';
    otherController.text = transaction['Other']?.toString() ?? '';
    remarksController.text = transaction['Remarks']?.toString() ?? '';

    image1Bytes = null;
    image2Bytes = null;
    _loadExistingImages();

    // Keep custom categories instead of silently dropping them.
    final category = transaction['CategoryName']?.toString();
    if (category != null &&
        category.isNotEmpty &&
        !categories.contains(category)) {
      categories.add(category);
    }
    selectedCategory = category;

    final mode = transaction['Mode']?.toString();
    selectedMode = modes.contains(mode) ? mode : null;

    final type = transaction['Type']?.toString();
    selectedType = types.contains(type) ? type : null;
  }

  // -----------------------------
  // Date formatter / picker
  // -----------------------------

  String formatDate(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year.toString();
    return '$day-$month-$year';
  }

  Future<DateTime?> pickDate(DateTime initialDate) async {
    return await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
  }

  Future<void> selectTransactionDate() async {
    final picked = await pickDate(transactionDate);
    if (picked != null) {
      setState(() => transactionDate = picked);
    }
  }

  // -----------------------------
  // Save transaction
  // -----------------------------

  Future<void> saveTransaction() async {
    if (isSaving || imagesLoading) return;
    final description = descriptionController.text.trim();
    final amount = double.tryParse(amountController.text.trim());
    if (description.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please Write Description')));
      return;
    }
    if (amount == null || !amount.isFinite || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Enter a valid positive amount')));
      return;
    }
    if (selectedType == null || selectedMode == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please select both Type and Mode')));
      return;
    }
    setState(() => isSaving = true);
    try {
      // Device local time (IST on the user's phone), no fake UTC offset.
      final now = DateTime.now();
      final payload = <String, dynamic>{
        'TranDate': formatApiDate(transactionDate),
        'Description': description,
        'Amount': amount,
        'Type': selectedType,
        'Mode': selectedMode,
        'Remarks': remarksController.text.trim().isEmpty
            ? null
            : remarksController.text.trim(),
        'Other': otherController.text.trim().isEmpty
            ? null
            : otherController.text.trim(),
        'CategoryName': selectedCategory,
        'CreationDate': isEditing
            ? (widget.transaction!['CreationDate'] ?? now.toIso8601String())
            : now.toIso8601String(),
        'IsDeleted': 0,
        'Image1Path': null,
        'Image2Path': null,
        'Image1Blob': image1Bytes,
        'Image2Blob': image2Bytes,
      };
      if (isEditing) {
        await LocalTransactionDatabase.instance
            .update((widget.transaction!['id'] as num).toInt(), payload);
      } else {
        await LocalTransactionDatabase.instance.insert(payload);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(isEditing
              ? 'Transaction updated successfully'
              : 'Transaction saved successfully')));
      Navigator.pop(context, true);
    } catch (e, st) {
      debugPrint('LOCAL SAVE ERROR: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not save transaction locally: $e')));
    } finally {
      if (mounted) setState(() => isSaving = false);
    }
  }

  String formatApiDate(DateTime date) {
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '$year-$month-$day';
  }

  // -----------------------------
  // Clear / refresh form
  // -----------------------------

  void clearForm() {
    setState(() {
      amountController.clear();
      otherController.clear();
      remarksController.clear();
      descriptionController.clear();

      _applyDefaults();

      image1Bytes = null;
      image2Bytes = null;

      transactionDate = DateTime.now();
    });
  }

  void refreshForm() {
    if (isEditing) {
      setState(() {
        amountController.clear();
        otherController.clear();
        remarksController.clear();
        descriptionController.clear();
        selectedCategory = null;
        selectedMode = null;
        selectedType = null;
        transactionDate = DateTime.now();
        _loadTransactionIntoForm();
      });
    } else {
      clearForm();
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Form refreshed')),
    );
  }

  // -----------------------------
  // Dispose
  // -----------------------------

  @override
  void dispose() {
    amountController.dispose();
    otherController.dispose();
    remarksController.dispose();
    descriptionController.dispose();
    super.dispose();
  }

  // ==================================================
  // UI
  // ==================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Transaction' : 'New Transaction'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final isNarrow = constraints.maxWidth < 800;

                // Wide layout: change the order of widgets in leftForm / rightForm.
                final leftForm = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildDateRow(
                      label: 'Date :',
                      date: transactionDate,
                      onPressed: selectTransactionDate,
                    ),
                    const SizedBox(height: 16),
                    _buildDropdownRow(
                      label: 'Category :',
                      value: selectedCategory,
                      items: categories,
                      onChanged: (value) =>
                          setState(() => selectedCategory = value),
                    ),
                    const SizedBox(height: 16),
                    _buildDropdownRow(
                      label: 'Mode :',
                      value: selectedMode,
                      items: modes,
                      onChanged: (value) =>
                          setState(() => selectedMode = value),
                    ),
                    const SizedBox(height: 16),
                    _buildDropdownRow(
                      label: 'Type :',
                      value: selectedType,
                      items: types,
                      onChanged: (value) =>
                          setState(() => selectedType = value),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(
                          width: 150,
                          child: Padding(
                            padding: EdgeInsets.only(top: 10),
                            child: Text('Description :'),
                          ),
                        ),
                        Expanded(
                          child: TextField(
                            controller: descriptionController,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              hintText: 'Write description',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                  ],
                );

                final rightForm = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildTextFieldRow(
                      label: 'Amount :',
                      controller: amountController,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                    ),
                    const SizedBox(height: 16),
                    _buildTextFieldRow(
                      label: 'Other :',
                      controller: otherController,
                    ),
                    const SizedBox(height: 16),
                    _buildTextFieldRow(
                      label: 'Remarks :',
                      controller: remarksController,
                    ),
                  ],
                );

                final formActions = Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    FilledButton.icon(
                      onPressed:
                          (isSaving || imagesLoading) ? null : saveTransaction,
                      icon: isSaving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : Icon(isEditing ? Icons.save_outlined : Icons.check),
                      label: Text(isSaving
                          ? 'Saving...'
                          : (isEditing
                              ? 'Update transaction'
                              : 'Save transaction')),
                    ),
                    OutlinedButton.icon(
                      onPressed: refreshForm,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh'),
                    ),
                  ],
                );

                // Phone layout: change the order of widgets here.
                if (isNarrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildDateRow(
                          label: 'Date',
                          date: transactionDate,
                          onPressed: selectTransactionDate),
                      const SizedBox(height: 14),
                      _buildDropdownRow(
                          label: 'Category',
                          value: selectedCategory,
                          items: categories,
                          onChanged: (value) =>
                              setState(() => selectedCategory = value)),
                      const SizedBox(height: 14),
                      _buildDropdownRow(
                          label: 'Mode',
                          value: selectedMode,
                          items: modes,
                          onChanged: (value) =>
                              setState(() => selectedMode = value)),
                      const SizedBox(height: 14),
                      _buildDropdownRow(
                          label: 'Type',
                          value: selectedType,
                          items: types,
                          onChanged: (value) =>
                              setState(() => selectedType = value)),
                      const SizedBox(height: 14),
                      _buildTextFieldRow(
                          label: 'Amount',
                          controller: amountController,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true)),
                      const SizedBox(height: 14),
                      _buildTextFieldRow(
                          label: 'Description',
                          controller: descriptionController),
                      const SizedBox(height: 14),
                      _buildTextFieldRow(
                          label: 'Remarks', controller: remarksController),
                      const SizedBox(height: 14),
                      _buildTextFieldRow(
                          label: 'Other', controller: otherController),
                      const SizedBox(height: 18),
                      const Align(
                          alignment: Alignment.centerLeft,
                          child: Text('Receipt images (optional, up to 2)',
                              style: TextStyle(fontWeight: FontWeight.w600))),
                      const SizedBox(height: 8),
                      Row(children: [
                        _buildImageAttachmentCard(slot: 1, bytes: image1Bytes),
                        const SizedBox(width: 12),
                        _buildImageAttachmentCard(slot: 2, bytes: image2Bytes),
                      ]),
                      const SizedBox(height: 20),
                      formActions,
                    ],
                  );
                }

                return Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: leftForm),
                        const SizedBox(width: 30),
                        Expanded(child: rightForm),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      _buildImageAttachmentCard(slot: 1, bytes: image1Bytes),
                      const SizedBox(width: 12),
                      _buildImageAttachmentCard(slot: 2, bytes: image2Bytes),
                    ]),
                    const SizedBox(height: 20),
                    Align(
                        alignment: Alignment.centerRight, child: formActions),
                  ],
                );
              },
            ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }

  // ==================================================
  // HELPER WIDGETS
  // ==================================================

  Widget _buildDateRow({
    required String label,
    required DateTime date,
    required VoidCallback onPressed,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final field = InkWell(
          onTap: onPressed,
          child: InputDecorator(
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              suffixIcon: Icon(Icons.calendar_today, size: 20),
            ),
            child: Text(formatDate(date)),
          ),
        );
        if (constraints.maxWidth < 600) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              field,
            ],
          );
        }
        return Row(
          children: [
            SizedBox(
                width: 150,
                child: Text(label, style: const TextStyle(fontSize: 16))),
            Expanded(child: field),
          ],
        );
      },
    );
  }

  Widget _buildTextFieldRow({
    required String label,
    required TextEditingController controller,
    TextInputType? keyboardType,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDescription = label.toLowerCase().startsWith('description');
        final field = TextField(
          controller: controller,
          keyboardType: keyboardType,
          maxLines: isDescription ? 3 : 1,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: isDescription ? 'Write description' : null,
          ),
        );
        if (constraints.maxWidth < 600) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              field,
            ],
          );
        }
        return Row(
          children: [
            SizedBox(
                width: 120,
                child: Text(label, style: const TextStyle(fontSize: 16))),
            Expanded(child: field),
          ],
        );
      },
    );
  }

  Widget _buildDropdownRow({
    required String label,
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // initialValue is only read once, so the key forces the field to
        // rebuild when `value` changes (e.g. after Refresh / clear form).
        final field = DropdownButtonFormField<String>(
          key: ValueKey(value),
          initialValue: value,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: items
              .map((item) => DropdownMenuItem<String>(
                    value: item,
                    child: Text(item, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: onChanged,
        );
        if (constraints.maxWidth < 600) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              field,
            ],
          );
        }
        return Row(
          children: [
            SizedBox(
                width: 150,
                child: Text(label, style: const TextStyle(fontSize: 16))),
            Expanded(child: field),
          ],
        );
      },
    );
  }
}