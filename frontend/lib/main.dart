import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:file_saver/file_saver.dart';

const String apiBaseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://daytoday-5d2d.onrender.com',
);

void main() {
  runApp(const MyApp());
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
      title: 'Day2Day v1.0',
      /*theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
        ),
        useMaterial3: true,
      ),*/

      
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
      borderSide: const BorderSide(
        color: Color(0xFFE2E8F0),
      ),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(
        color: Color(0xFFE2E8F0),
      ),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(
        color: Color(0xFF2563EB),
        width: 1.5,
      ),
    ),
  ),

  elevatedButtonTheme: ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      padding: const EdgeInsets.symmetric(
        horizontal: 18,
        vertical: 14,
      ),
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
  String message = "Loading...";

  // All transactions
  final List<Map<String, dynamic>> transactions = [];

  // Full active history is retained so balances stay cumulative after date filtering.
  final List<Map<String, dynamic>> balanceTransactions = [];

  // Search dates
  DateTime fromDate = DateTime.now();
  DateTime toDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    fetchMessage();
    fetchTransactions();
  }

  // --------------------------------------------------
  // GET MESSAGE FROM BACKEND
  // --------------------------------------------------

  Future<void> fetchMessage() async {
    try {
      final url = Uri.parse('$apiBaseUrl/');

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        setState(() {
          message = data['message'];
        });
      } else {
        setState(() {
          message = "Server error";
        });
      }
    } catch (e) {
      print("API ERROR: $e");

      setState(() {
        message = "Backend unavailable. Check internet and try again.";
      });
    }
  }

// --------------------------------------------------
  // GET Transactions FROM BACKEND
  // --------------------------------------------------

Future<void> fetchTransactions({bool searchByDate = false}) async {
  try {
    final Uri url;

    if (searchByDate) {
      final from = DateTime(fromDate.year, fromDate.month, fromDate.day);
      final to = DateTime(toDate.year, toDate.month, toDate.day);

      if (from.isAfter(to)) {
        if (!mounted) return;

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('From date cannot be after To date'),
          ),
        );
        return;
      }

      url = Uri.parse('$apiBaseUrl/transactions/search').replace(
        queryParameters: {
          'from_date': _apiDate(fromDate),
          'to_date': _apiDate(toDate),
        },
      );
    } else {
      url = Uri.parse('$apiBaseUrl/transactions');
    }

    final response = await http.get(url);

    if (response.statusCode != 200) {
      throw Exception(
        'GET transactions failed: ${response.statusCode} '
        '${response.body}',
      );
    }

    final List<dynamic> data = jsonDecode(response.body);

    // A date search changes the visible rows, but running balances must be
    // calculated from the complete active transaction history.
    final List<dynamic> allData;
    if (searchByDate) {
      final allResponse = await http.get(
        Uri.parse('$apiBaseUrl/transactions'),
      );
      if (allResponse.statusCode != 200) {
        throw Exception(
          'GET all transactions for balance failed: '
          '${allResponse.statusCode} ${allResponse.body}',
        );
      }
      allData = jsonDecode(allResponse.body) as List<dynamic>;
    } else {
      allData = data;
    }

    if (!mounted) return;

    setState(() {
      transactions
        ..clear()
        ..addAll(
          data.map((item) => Map<String, dynamic>.from(item as Map)),
        );
      balanceTransactions
        ..clear()
        ..addAll(
          allData.map((item) => Map<String, dynamic>.from(item as Map)),
        );
    });
  } catch (e, stackTrace) {
    debugPrint('FETCH TRANSACTIONS ERROR: $e');
    debugPrintStack(stackTrace: stackTrace);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not load transactions: $e')),
    );
  }
}

String _apiDate(DateTime date) {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');

  return '$year-$month-$day';
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
      setState(() {
        fromDate = picked;
      });
    }
  }

  Future<void> selectToDate() async {
    final picked = await pickDate(toDate);

    if (picked != null) {
      setState(() {
        toDate = picked;
      });
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

  // --------------------------------------------------
  // OPEN NEW TRANSACTION PAGE
  // --------------------------------------------------
Future<void> openNewTransaction() async {
  final saved = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
      builder: (context) => const AddExpensePage(),
    ),
  );

  if (saved == true) {
    await fetchTransactions();
  }
}

Future<void> openEditTransaction(Map<String, dynamic> transaction) async {
  final saved = await Navigator.push<bool>(
    context,
    MaterialPageRoute(
      builder: (context) => AddExpensePage(transaction: transaction),
    ),
  );

  if (saved == true) {
    await fetchTransactions();
  }
}

  // --------------------------------------------------
  // FILTER TRANSACTIONS
  // --------------------------------------------------

  List<Map<String, dynamic>> get filteredTransactions {
    return transactions;
  }

  double _amountOf(Map<String, dynamic> transaction) {
    return double.tryParse(transaction['Amount']?.toString() ?? '') ?? 0.0;
  }

  bool _isIncome(Map<String, dynamic> transaction) {
    return (transaction['Type']?.toString().trim().toLowerCase() ?? '') == 'income';
  }

  bool _isExpense(Map<String, dynamic> transaction) {
    return (transaction['Type']?.toString().trim().toLowerCase() ?? '') == 'expense';
  }

  double get totalIncome => filteredTransactions
      .where(_isIncome)
      .fold(0.0, (sum, transaction) => sum + _amountOf(transaction));

  double get totalExpenses => filteredTransactions
      .where(_isExpense)
      .fold(0.0, (sum, transaction) => sum + _amountOf(transaction));

  double get netBalance => totalIncome - totalExpenses;

  // Running balance within the currently displayed set (all records or selected date range).
  Map<String, double> get runningBalances {
    final chronological = List<Map<String, dynamic>>.from(balanceTransactions);
    chronological.sort((a, b) {
      final dateA = DateTime.tryParse(a['TranDate']?.toString() ?? '') ?? DateTime(2000);
      final dateB = DateTime.tryParse(b['TranDate']?.toString() ?? '') ?? DateTime(2000);
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

  String _formatAmount(double amount) =>
      '₹${amount.toStringAsFixed(2)}';

/*
  Widget _summaryCard(String title, double amount, IconData icon) {
    return SizedBox(
      width: 220,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(icon, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 6),
                    Text(
                      _formatAmount(amount),
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
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
  }*/

  
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
        side: const BorderSide(
          color: Color(0xFFE8EDF4),
        ),
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
                    Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.w600))),
                  ]),
                  const SizedBox(height: 5),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(_formatAmount(amount), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
                  ),
                ],
              )
            : Row(
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: accentColor.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(icon, color: accentColor, size: 25),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: const TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w500)),
                        const SizedBox(height: 8),
                        Text(_formatAmount(amount), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFF0F172A))),
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
    return Scaffold(
      /*appBar: AppBar(
        title: const Text("Day To Day"),
      ),*/

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
        style: TextStyle(
          fontWeight: FontWeight.bold,
          letterSpacing: -0.4,
        ),
      ),
    ],
  ),
),

      body: Padding(
        padding: const EdgeInsets.all(16),

        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,

          children: [

            // ------------------------------------------
            // BACKEND MESSAGE
            // ------------------------------------------

            if (message != 'Hello Welcome')
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: message.startsWith('Backend unavailable')
                      ? const Color(0xFFFFF1F2)
                      : const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 12,
                    color: message.startsWith('Backend unavailable')
                        ? const Color(0xFFBE123C)
                        : const Color(0xFF1D4ED8),
                  ),
                ),
              ),

            // ------------------------------------------
            // NEW and BACKUP buttons
            // ------------------------------------------
            /*Row(
            children: [
              ElevatedButton.icon(
                onPressed: openNewTransaction,
                icon: const Icon(Icons.add),
                label: const Text('New'),
              ),
          
              const SizedBox(width: 12),
          
              ElevatedButton.icon(
                onPressed: exportTransactionsToExcel,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('Backup'),
              ),
            ],
          ),*/

          
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
            // SEARCH BAR
            // ------------------------------------------

            /*Row(
              children: [

                const Text(
                  "From :",
                  style: TextStyle(fontSize: 16),
                ),

                const SizedBox(width: 8),

                _buildDateField(
                  date: fromDate,
                  onPressed: selectFromDate,
                ),

                const SizedBox(width: 10),

                const Text(
                  "To :",
                  style: TextStyle(fontSize: 16),
                ),

                const SizedBox(width: 8),

                _buildDateField(
                  date: toDate,
                  onPressed: selectToDate,
                ),

                const SizedBox(width: 12),

                ElevatedButton(
                  onPressed: () => fetchTransactions(searchByDate: true),
                  child: const Text('Search'),
              )
              ],
            ),*/

            
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 600;
                if (narrow) {
                  return Column(
                    children: [
                      Row(children: [
                        const SizedBox(width: 42, child: Text('From', style: TextStyle(fontSize: 12))),
                        Expanded(child: _buildDateField(date: fromDate, onPressed: selectFromDate, compact: true)),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        const SizedBox(width: 42, child: Text('To', style: TextStyle(fontSize: 12))),
                        Expanded(child: _buildDateField(date: toDate, onPressed: selectToDate, compact: true)),
                      ]),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => fetchTransactions(searchByDate: true),
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

            // ------------------------------------------
            // INCOME / EXPENSE / BALANCE SUMMARY
            // Totals use the currently loaded records, so date search applies.
            // ------------------------------------------
            LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 600;
                final cardWidth = narrow
                    ? (constraints.maxWidth - 12) / 3
                    : 240.0;
                return Row(
                  children: [
                    Expanded(child: _summaryCard('Income', totalIncome, Icons.trending_up, const Color(0xFF16A34A), width: cardWidth, compact: narrow)),
                    const SizedBox(width: 6),
                    Expanded(child: _summaryCard('Expenses', totalExpenses, Icons.trending_down, const Color(0xFFDC2626), width: cardWidth, compact: narrow)),
                    const SizedBox(width: 6),
                    Expanded(child: _summaryCard('Balance', netBalance, Icons.account_balance_wallet_outlined, const Color(0xFF2563EB), width: cardWidth, compact: narrow)),
                  ],
                );
              },
            ),

            const SizedBox(height: 12),

            // ------------------------------------------
            // TRANSACTION TABLE
            // ------------------------------------------

            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,

                child: SingleChildScrollView(
                  child: DataTable(
                    /*border: TableBorder.all(
                      color: Colors.grey,
                    ),*/

                    
                border: const TableBorder(
                  horizontalInside: BorderSide(
                    color: Color(0xFFE8EDF4),
                  ),
                ),
                headingRowColor: MaterialStatePropertyAll(
                  Color(0xFFEFF4FF),
                ),
                headingRowHeight: 54,
                dataRowMinHeight: 54,
                dataRowMaxHeight: 66,
                columnSpacing: 24,
                horizontalMargin: 16,


                    columns: const [

                      DataColumn(
                        label: Text("Transaction No."),
                      ),

                      DataColumn(
                        label: Text("Transaction Date"),
                      ),

                      DataColumn(
                        label: Text("Description"),
                      ),

                      DataColumn(
                        label: Text("Amount"),
                      ),

                      DataColumn(
                        label: Text("Type"),
                      ),

                      DataColumn(
                        label: Text("Mode"),
                      ),

                      DataColumn(
                        label: Text("Remarks"),
                      ),

                      DataColumn(
                        label: Text("Other"),
                      ),

                      DataColumn(
                        label: Text("CategoryName"),
                      ),

                      DataColumn(
                        label: Text("Balance"),
                      ),

                      const DataColumn(
                        label: Text('Actions'),
                      ),
                    ],

                    rows: filteredTransactions.map((transaction) {

                      return 
DataRow(
  cells: [
    DataCell(Text('${transaction['id']}')),
    DataCell(
  Text(
    formatDate(
      DateTime.parse(transaction['TranDate'].toString()),
    ),
  ),
),
    DataCell(Text(transaction['Description']?.toString() ?? '')),
    DataCell(Text(transaction['Amount'].toString())),
    DataCell(Text(transaction['Type']?.toString() ?? '')),
    DataCell(Text(transaction['Mode']?.toString() ?? '')),
    DataCell(Text(transaction['Remarks']?.toString() ?? '')),
    DataCell(Text(transaction['Other']?.toString() ?? '')),
    DataCell(Text(transaction['CategoryName']?.toString() ?? '')),
    DataCell(Text(_formatAmount(runningBalances[transaction['id'].toString()] ?? 0.0))),
   DataCell(
     Row(
       mainAxisSize: MainAxisSize.min,
       children: [
         IconButton(
           tooltip: 'Edit transaction',
           icon: const Icon(Icons.edit_outlined, color: Colors.blue),
           onPressed: () => openEditTransaction(transaction),
         ),
         IconButton(
           tooltip: 'Delete transaction',
           icon: const Icon(Icons.delete_outline, color: Colors.red),
           onPressed: () {
             final id = int.parse(transaction['id'].toString());
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
            contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: compact ? 10 : 14),
            border: const OutlineInputBorder(),
            suffixIcon: const Icon(Icons.calendar_today, size: 18),
          ),

          child: Text(
            formatDate(date),
          ),
        ),
      ),
    );
  }


Future<void> exportTransactionsToExcel() async {
  try {
    final response = await http.get(
      Uri.parse('$apiBaseUrl/transactions/export'),
    );

    if (response.statusCode != 200) {
      throw Exception(
        'Export failed: ${response.statusCode} ${response.body}',
      );
    }

    // Read the filename supplied by FastAPI.
    final contentDisposition =
        response.headers['content-disposition'];

    final filenameMatch = contentDisposition == null
        ? null
        : RegExp(
            r'filename="?([^";]+)"?',
            caseSensitive: false,
          ).firstMatch(contentDisposition);

    final filename = filenameMatch?.group(1) ??
        'Transactions_backup_till_${DateTime.now().toLocal().toString().replaceAll(':', '-').replaceAll(' ', '_').split('.').first}';

    final savedPath = await FileSaver.instance.saveFile(
      name: filename.replaceAll(RegExp(r'\.xlsx$', caseSensitive: false), ''),
      bytes: response.bodyBytes,
      fileExtension: 'xlsx',
      mimeType: MimeType.microsoftExcel,
    );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          savedPath != null && savedPath.isNotEmpty
              ? 'Excel backup saved: $savedPath'
              : 'Backup request completed. Check Downloads or the save location selected by Android.',
        ),
      ),
    );
  } catch (e, stackTrace) {
    debugPrint('EXCEL EXPORT ERROR: $e');
    debugPrintStack(stackTrace: stackTrace);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Excel export failed: $e'),
      ),
    );
  }
}

Future<void> deleteTransaction(int id) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete transaction?'),
      content: Text(
        //'Transaction #$id will be hidden from normal history. '
        //'It will remain in the database.',
        'Transaction #$id will be deleted from your history. '
      ),
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
    final response = await http.delete(
      Uri.parse('$apiBaseUrl/transactions/$id'),
    );

    if (!mounted) return;

    if (response.statusCode == 200) {
      await fetchTransactions();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Transaction #$id deleted')),
      );
    } else {
      throw Exception(
        'HTTP ${response.statusCode}: ${response.body}',
      );
    }
  } catch (e, stackTrace) {
    debugPrint('DELETE TRANSACTION ERROR: $e');
    debugPrintStack(stackTrace: stackTrace);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not delete transaction: $e')),
    );
  }
}


}
// --------------------------------------------------
// ADD EXPENSE PAGE
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
  // -----------------------------
  // Controllers
  // -----------------------------

  final TextEditingController amountController =
      TextEditingController();

  final TextEditingController otherController =
      TextEditingController();

  final TextEditingController remarksController =
      TextEditingController();

  final TextEditingController descriptionController =
      TextEditingController();

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

  final List<String> modes = [
    'Cash',
    'UPI',
    'Card',
  ];

  final List<String> types = [
    'Expense',
    'Income',
  ];

  // -----------------------------
  // Dates
  // -----------------------------

  DateTime transactionDate = DateTime.now();

  bool get isEditing => widget.transaction != null;

  @override
  void initState() {
    super.initState();
    _loadTransactionIntoForm();
  }

  void _loadTransactionIntoForm() {
    final transaction = widget.transaction;
    if (transaction == null) return;

    transactionDate = DateTime.parse(transaction['TranDate'].toString());
    descriptionController.text =
        transaction['Description']?.toString() ?? '';
    amountController.text = transaction['Amount']?.toString() ?? '';
    otherController.text = transaction['Other']?.toString() ?? '';
    remarksController.text = transaction['Remarks']?.toString() ?? '';

    final category = transaction['CategoryName']?.toString();
    selectedCategory = categories.contains(category) ? category : null;

    final mode = transaction['Mode']?.toString();
    selectedMode = modes.contains(mode) ? mode : null;

    final type = transaction['Type']?.toString();
    selectedType = types.contains(type) ? type : null;
  }

  // -----------------------------
  // Date formatter
  // -----------------------------

  String formatDate(DateTime date) {
    final day = date.day.toString().padLeft(2, '0');
    final month = date.month.toString().padLeft(2, '0');
    final year = date.year.toString();

    return '$day-$month-$year';
  }

  // -----------------------------
  // Date picker
  // -----------------------------

  Future<DateTime?> pickDate(DateTime initialDate) async {
    return await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
  }

  // -----------------------------
  // Select transaction date
  // -----------------------------

  Future<void> selectTransactionDate() async {
    final picked = await pickDate(transactionDate);

    if (picked != null) {
      setState(() {
        transactionDate = picked;
      });
    }
  }
  
  // -----------------------------
  // Save transaction
  // -----------------------------
  
Future<void> saveTransaction() async {
  final description = descriptionController.text.trim();
  final amountText = amountController.text.trim();

  if (description.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Please enter Description')),
    );
    return;
  }

  final amount = double.tryParse(amountText);

  if (amount == null || !amount.isFinite || amount <= 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Enter a valid positive amount')),
    );
    return;
  }

  if (selectedType == null || selectedMode == null) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Please select both Type and Mode'),
    ),
  );
  return;
}

  final payload = {
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
  };

  try {
    final uri = isEditing
        ? Uri.parse('$apiBaseUrl/transactions/${widget.transaction!['id']}')
        : Uri.parse('$apiBaseUrl/transactions');

    final response = isEditing
        ? await http.put(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
        : await http.post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          );

    if (!mounted) return;

    if (response.statusCode == 200 ||
        response.statusCode == 201) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isEditing
                ? 'Transaction updated successfully'
                : 'Transaction saved successfully',
          ),
        ),
      );

      Navigator.pop(context, true);
    } else {
      debugPrint('SAVE ERROR: ${response.statusCode}');
      debugPrint('Response: ${response.body}');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Save failed (${response.statusCode}): ${response.body}',
          ),
        ),
      );
    }
  } catch (e, stackTrace) {
    debugPrint('SAVE TRANSACTION ERROR: $e');
    debugPrintStack(stackTrace: stackTrace);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not connect to backend: $e')),
    );
  }
}

String formatApiDate(DateTime date) {
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');

  return '$year-$month-$day';
}

  // -----------------------------
  // Clear form
  // -----------------------------

  void clearForm() {
    setState(() {
      amountController.clear();
      otherController.clear();
      remarksController.clear();
      descriptionController.clear();

      selectedCategory = null;
      selectedMode = null;
      selectedType = null;

      transactionDate = DateTime.now();
    });
  }

  // -----------------------------
  // Refresh
  // -----------------------------

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
      const SnackBar(
        content: Text('Form refreshed'),
      ),
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

            // ==================================================
            // FORM
            // ==================================================

            /*Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [

                // -----------------------------
                // LEFT SIDE
                // -----------------------------

                Expanded(
                  child: Column(
                    children: [

                      // DATE
                      _buildDateRow(
                        label: 'Date :',
                        date: transactionDate,
                        onPressed: selectTransactionDate,
                      ),

                      const SizedBox(height: 16),

                      // CATEGORY
                      _buildDropdownRow(
                        label: 'Category :',
                        value: selectedCategory,
                        items: categories,
                        onChanged: (value) {
                          setState(() {
                            selectedCategory = value;
                          });
                        },
                      ),

                      const SizedBox(height: 16),

                      // MODE
                      _buildDropdownRow(
                        label: 'Mode :',
                        value: selectedMode,
                        items: modes,
                        onChanged: (value) {
                          setState(() {
                            selectedMode = value;
                          });
                        },
                      ),

                      const SizedBox(height: 16),

                      // TYPE
                      _buildDropdownRow(
                        label: 'Type :',
                        value: selectedType,
                        items: types,
                        onChanged: (value) {
                          setState(() {
                            selectedType = value;
                          });
                        },
                      ),

                      const SizedBox(height: 16),

                      // DESCRIPTION
                      Row(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [

                          const SizedBox(
                            width: 150,
                            child: Padding(
                              padding: EdgeInsets.only(top: 10),
                              child: Text(
                                'Description :',
                                style: TextStyle(
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),

                          Expanded(
                            child: TextField(
                              controller:
                                  descriptionController,
                              maxLines: 4,
                              decoration:
                                  const InputDecoration(
                                border:
                                    OutlineInputBorder(),
                                hintText:
                                    'Enter description',
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 10),

                      // BUTTONS
                      Row(
                        children: [

                          const SizedBox(width: 150),

                          ElevatedButton(
                            onPressed: saveTransaction,
                            child: Text(isEditing ? 'Update' : 'Save'),
                          ),

                          const SizedBox(width: 16),

                          ElevatedButton(
                            onPressed: refreshForm,
                            child: const Text('Refresh'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 30),

                // -----------------------------
                // RIGHT SIDE
                // -----------------------------

                Expanded(
                  child: Column(
                    children: [

                      // AMOUNT
                      _buildTextFieldRow(
                        label: 'Amount :',
                        controller: amountController,
                        keyboardType:
                            TextInputType.number,
                      ),

                      const SizedBox(height: 16),

                      // OTHER
                      _buildTextFieldRow(
                        label: 'Other :',
                        controller: otherController,
                      ),

                      const SizedBox(height: 16),

                      // REMARKS
                      _buildTextFieldRow(
                        label: 'Remarks :',
                        controller: remarksController,
                      ),
                    ],
                  ),
                ),
              ],
            ),*/

            
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 800;

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
                    onChanged: (value) {
                      setState(() => selectedCategory = value);
                    },
                  ),
                  const SizedBox(height: 16),
                  _buildDropdownRow(
                    label: 'Mode :',
                    value: selectedMode,
                    items: modes,
                    onChanged: (value) {
                      setState(() => selectedMode = value);
                    },
                  ),
                  const SizedBox(height: 16),
                  _buildDropdownRow(
                    label: 'Type :',
                    value: selectedType,
                    items: types,
                    onChanged: (value) {
                      setState(() => selectedType = value);
                    },
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
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
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
                    onPressed: saveTransaction,
                    icon: Icon(isEditing ? Icons.save_outlined : Icons.check),
                    label: Text(isEditing ? 'Update transaction' : 'Save transaction'),
                  ),
                  OutlinedButton.icon(
                    onPressed: refreshForm,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh'),
                  ),
                ],
              );

              if (isNarrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildDateRow(label: 'Date', date: transactionDate, onPressed: selectTransactionDate),
                    const SizedBox(height: 14),
                    _buildDropdownRow(label: 'Category', value: selectedCategory, items: categories,
                      onChanged: (value) => setState(() => selectedCategory = value)),
                    const SizedBox(height: 14),
                    _buildDropdownRow(label: 'Mode', value: selectedMode, items: modes,
                      onChanged: (value) => setState(() => selectedMode = value)),
                    const SizedBox(height: 14),
                    _buildDropdownRow(label: 'Type', value: selectedType, items: types,
                      onChanged: (value) => setState(() => selectedType = value)),
                    const SizedBox(height: 14),
                    _buildTextFieldRow(label: 'Description', controller: descriptionController),
                    const SizedBox(height: 14),
                    _buildTextFieldRow(label: 'Amount', controller: amountController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                    const SizedBox(height: 14),
                    _buildTextFieldRow(label: 'Other', controller: otherController),
                    const SizedBox(height: 14),
                    _buildTextFieldRow(label: 'Remarks', controller: remarksController),
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
                  const SizedBox(height: 20),
                  Align(alignment: Alignment.centerRight, child: formActions),
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
                child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              field,
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 150, child: Text(label, style: const TextStyle(fontSize: 16))),
            Expanded(child: field),
          ],
        );
      },
    );
  }

  Widget _buildSmallDateField({
    required DateTime date,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 150,
      child: InkWell(
        onTap: onPressed,
        child: InputDecorator(
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            suffixIcon: Icon(Icons.calendar_today),
          ),
          child: Text(formatDate(date)),
        ),
      ),
    );
  }

  Widget _buildTextFieldRow({
    required String label,
    required TextEditingController controller,
    TextInputType? keyboardType,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final field = TextField(
          controller: controller,
          keyboardType: keyboardType,
          maxLines: label.toLowerCase().startsWith('description') ? 3 : 1,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: label.toLowerCase().startsWith('description') ? 'Enter description' : null,
          ),
        );
        if (constraints.maxWidth < 600) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              field,
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 120, child: Text(label, style: const TextStyle(fontSize: 16))),
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
        final field = DropdownButtonFormField<String>(
          value: value,
          isExpanded: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          items: items.map((item) => DropdownMenuItem<String>(
            value: item,
            child: Text(item, overflow: TextOverflow.ellipsis),
          )).toList(),
          onChanged: onChanged,
        );
        if (constraints.maxWidth < 600) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              field,
            ],
          );
        }
        return Row(
          children: [
            SizedBox(width: 150, child: Text(label, style: const TextStyle(fontSize: 16))),
            Expanded(child: field),
          ],
        );
      },
    );
  }

}