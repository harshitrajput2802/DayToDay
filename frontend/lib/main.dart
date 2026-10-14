import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:excel/excel.dart' hide Border;
import 'package:flutter/material.dart' as flutter;

import 'package:file_saver/file_saver.dart';
import 'package:open_filex/open_filex.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:image_picker/image_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

final FlutterLocalNotificationsPlugin backupNotifications =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  static String _date(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

// --------------------------------------------------
// APP
// --------------------------------------------------

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Day2Day',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2563EB),
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F7FB),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Color(0xFF0F172A),
          elevation: 0,
          surfaceTintColor: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
      home: const HomePage(),
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

    fetchTransactions(searchByDate: true);
  }

  @override
  void dispose() {
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
      });
    } catch (e, st) {
      debugPrint('LOCAL FETCH ERROR: $e');
      debugPrintStack(stackTrace: st);
      if (!mounted) return;
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

  Future<void> openNewTransaction() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => const AddExpensePage()),
    );
    if (saved == true) await _reload();
  }

  Future<void> openEditTransaction(Map<String, dynamic> transaction) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => AddExpensePage(transaction: transaction),
      ),
    );
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

  Widget _summaryCard(
    String title,
    double amount,
    IconData icon,
    Color accentColor, {
    double? width,
    bool compact = false,
  }) {
    return SizedBox(
      width: width ?? 240,
      child: Card(
        color: Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFE8EDF4)),
        ),
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
                          style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF64748B),
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 5),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _formatAmount(amount),
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0F172A)),
                      ),
                    ),
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
                          Text(title,
                              style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF64748B),
                                  fontWeight: FontWeight.w500)),
                          const SizedBox(height: 8),
                          Text(_formatAmount(amount),
                              style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF0F172A))),
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
  // BUILD MAIN SCREEN
  // --------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final balances = runningBalances;

    return Scaffold(
      appBar: AppBar(
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
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Exit application',
            icon: const Icon(Icons.power_settings_new,
                color: Colors.red, size: 28),
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
                          backgroundColor: Colors.red),
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
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ------------------------------------------
            // TAGLINE
            // ------------------------------------------
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 10),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                message,
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFF1D4ED8)),
              ),
            ),

            // ------------------------------------------
            // NEW and BACKUP buttons
            // ------------------------------------------
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                ElevatedButton.icon(
                  onPressed: openNewTransaction,
                  icon: const Icon(Icons.add),
                  label: const Text('New'),
                ),
                ElevatedButton.icon(
                  onPressed: exportTransactionsToExcel,
                  icon: const Icon(Icons.file_download_outlined),
                  label: const Text('Backup'),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // ------------------------------------------
            // DATE FILTER
            // ------------------------------------------
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 600;
                if (narrow) {
                  return Column(
                    children: [
                      Row(children: [
                        const SizedBox(
                            width: 42,
                            child:
                                Text('From', style: TextStyle(fontSize: 12))),
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
                          onPressed: () =>
                              fetchTransactions(searchByDate: true),
                          icon: const Icon(Icons.search),
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

            const SizedBox(height: 12),

            // Search only within the Description column.
            TextField(
              controller: descriptionSearchController,
              onChanged: (value) => setState(() => descriptionSearch = value),
              decoration: InputDecoration(
                //hintText: 'Filter by description...',
                hintText: 'Search by description...',
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

            const SizedBox(height: 12),

            // ------------------------------------------
            // INCOME / EXPENSE / BALANCE SUMMARY
            // ------------------------------------------
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 600;
                final cardWidth =
                    narrow ? (constraints.maxWidth - 12) / 3 : 240.0;
                return Row(
                  children: [
                    Expanded(
                        child: _summaryCard('Income', totalIncome,
                            Icons.trending_up, const Color(0xFF16A34A),
                            width: cardWidth, compact: narrow)),
                    const SizedBox(width: 6),
                    Expanded(
                        child: _summaryCard('Expenses', totalExpenses,
                            Icons.trending_down, const Color(0xFFDC2626),
                            width: cardWidth, compact: narrow)),
                    const SizedBox(width: 6),
                    Expanded(
                        child: _summaryCard(
                            'Balance',
                            netBalance,
                            Icons.account_balance_wallet_outlined,
                            const Color(0xFF2563EB),
                            width: cardWidth,
                            compact: narrow)),
                  ],
                );
              },
            ),

            //const SizedBox(height: 12),

            // Fixed header
            SingleChildScrollView(
              controller: _headerHorizontalController,
              scrollDirection: Axis.horizontal,
              child: DataTable(
                    border: const TableBorder(
                      horizontalInside: BorderSide(color: Color(0xFFE8EDF4)),
                    ),
                    headingRowColor:
                        const WidgetStatePropertyAll(Color(0xFFEFF4FF)),
                    headingRowHeight: 54, // Change to 54 to view empty table also
                    dataRowMinHeight: 54,
                    dataRowMaxHeight: 66,
                    columnSpacing: 24,
                    horizontalMargin: 16,
                columns: const [
                      DataColumn(label: Text('Transaction No.', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Transaction Date', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Description', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Amount', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Type', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Mode', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Remarks', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Other', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('CategoryName', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Balance', style: TextStyle(fontWeight: FontWeight.bold))),
                      DataColumn(label: Text('Actions', style: TextStyle(fontWeight: FontWeight.bold))),
                ],
                rows: const [],
              ),
            ),

            //const SizedBox(height: 12),

            // ------------------------------------------
            // TRANSACTION TABLE
            // ------------------------------------------
            Expanded(
              child: SingleChildScrollView(
                controller: _bodyHorizontalController,
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: DataTable(
                    border: const TableBorder(
                      horizontalInside: BorderSide(color: Color(0xFFE8EDF4)),
                    ),
                    headingRowColor:
                        const WidgetStatePropertyAll(Color(0xFFEFF4FF)),
                    showCheckboxColumn: false,
                    headingRowHeight: 0,
                    dataRowMinHeight: 54,
                    dataRowMaxHeight: 66,
                    columnSpacing: 24,
                    horizontalMargin: 16,
                    columns: const [
                      DataColumn(label: SizedBox.shrink()),
                      DataColumn(label: SizedBox.shrink()),
                      DataColumn(label: SizedBox.shrink()),
                      DataColumn(label: SizedBox.shrink()),
                      DataColumn(label: SizedBox.shrink()),
                      DataColumn(label: SizedBox.shrink()),
                      DataColumn(label: SizedBox.shrink()),
                      DataColumn(label: SizedBox.shrink()),
                      DataColumn(label: SizedBox.shrink()),
                      DataColumn(label: SizedBox.shrink()),
                      DataColumn(label: SizedBox.shrink()),
                    ],
                    rows: filteredTransactions.map((transaction) {
                      return DataRow(
                        cells: [
                          DataCell(Text('${transaction['id']}')),
                          DataCell(Text(formatTransactionDate(DateTime.parse(
                              transaction['TranDate'].toString())))),
                          DataCell(Text(
                              transaction['Description']?.toString() ?? '')),
                          DataCell(Text(transaction['Amount'].toString())),
                          DataCell(
                              Text(transaction['Type']?.toString() ?? '')),
                          DataCell(
                              Text(transaction['Mode']?.toString() ?? '')),
                          DataCell(Text(
                              transaction['Remarks']?.toString() ?? '')),
                          DataCell(
                              Text(transaction['Other']?.toString() ?? '')),
                          DataCell(Text(
                              transaction['CategoryName']?.toString() ?? '')),
                          DataCell(Text(_formatAmount(
                              balances[transaction['id'].toString()] ?? 0.0))),
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_transactionHasImages(transaction))
                                  IconButton(
                                    tooltip: 'View transaction images',
                                    icon: const Icon(Icons.image_outlined,
                                        color: Colors.teal),
                                    onPressed: () =>
                                        _showTransactionImages(transaction),
                                  ),
                                IconButton(
                                  tooltip: 'Edit transaction',
                                  icon: const Icon(Icons.edit_outlined,
                                      color: Colors.blue),
                                  onPressed: () =>
                                      openEditTransaction(transaction),
                                ),
                                IconButton(
                                  tooltip: 'Delete transaction',
                                  icon: const Icon(Icons.delete_outline,
                                      color: Colors.red),
                                  onPressed: () {
                                    final id =
                                        int.parse(transaction['id'].toString());
                                    deleteTransaction(id);
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            ),
          ],
        ),
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
        title: Text('Images • Transaction #${transaction['id']}'),
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
                                child: IconButton.filledTonal(
                                  tooltip: 'Close image',
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
                          const Text('Tap to enlarge',
                              style:
                                  TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
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
        title: const Text('Delete transaction?'),
        content: Text('Transaction #$id will be deleted from your history.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
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
    'Cash Given',
    'Dairy',
    'Fruits',
    'Vegetables',
    'Grocery',
    'Food',
    'Fuel',
    'Travel',
    'Medicine',
    'Clothes',
    'Shoes',
    'Cosmetic',
    'Mobile Recharge',
    'Internet/Wi-Fi',
    'Books',
    'Stationery',
    'Other',
  ];

  final List<String> modes = ['Cash', 'UPI', 'Card'];

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
          const SnackBar(content: Text('Please enter Description')));
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
        title: Text(isEditing ? 'Edit Transaction' : 'Day To Day'),
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
                              hintText: 'Enter description',
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
            hintText: isDescription ? 'Enter description' : null,
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