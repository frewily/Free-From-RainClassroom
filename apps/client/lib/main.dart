import 'package:flutter/material.dart';

import 'login_page.dart';
import 'github/github_page.dart';
import 'github/github_client.dart';
import 'github/github_controller.dart';
import 'github/github_store.dart';
import 'client_support.dart';
import 'cloudflare/cloudflare_auth.dart';
import 'cloudflare/cloudflare_controller.dart';
import 'cloudflare/cloudflare_page.dart';
import 'deployment/deployment_controller.dart';
import 'deployment/deployment_model.dart';
import 'deployment/deployment_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RainClientApp());
}

class RainClientApp extends StatelessWidget {
  const RainClientApp({super.key, this.home});

  final Widget? home;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '雨课堂管理',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xfff5f4ed),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff28685e),
        primary: const Color(0xff28685e),
        surface: const Color(0xfff5f4ed),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xfff5f4ed),
        foregroundColor: Color(0xff173b3c),
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    ),
    home: home ?? const ConnectionHome(),
  );
}

class ConnectionHome extends StatefulWidget {
  const ConnectionHome({
    super.key,
    this.rainPage = const LoginPage(),
    this.githubPage,
    this.cloudPage,
    this.deploymentPage,
  });

  final Widget rainPage;
  final Widget? githubPage, cloudPage, deploymentPage;

  @override
  State<ConnectionHome> createState() => _ConnectionHomeState();
}

class _ConnectionHomeState extends State<ConnectionHome> {
  int _selected = 0;
  GithubController? _github;
  CloudController? _cloud;
  DeploymentController? _deployment;
  late final List<Widget> _pages;
  @override
  void initState() {
    super.initState();
    if (widget.githubPage == null) {
      _github = GithubController(
        client: GithubClient(),
        store: SecureGithubStore(),
      );
    }
    if (widget.cloudPage == null) {
      _cloud = CloudController(
        client: CloudClient(),
        store: SecureRecordStore(
          'top.frewily.rainclient.dev.cloudflare',
          'cloudflare.v1',
        ),
      );
    }
    if (widget.deploymentPage == null && _github != null && _cloud != null) {
      _deployment = DeploymentController(
        store: SecureRecordStore(
          'top.frewily.rainclient.dev.deployment',
          'deployment.test.v1',
        ),
        credentials: () async {
          final gh = await _github!.forDeployment();
          final repo = _github!.account!.repositories.singleWhere(
            (r) => r.id == gh.selectedRepositoryId,
          );
          if (repo.fullName != deploymentRepository) {
            throw const ClientFailure(ClientIssue.authorization);
          }
          final cf = await _cloud!.forDeployment();
          return DeploymentCredentials(
            githubToken: gh.tokens.access,
            cloudflareToken: cf.token,
            repositoryId: repo.id,
            userId: gh.accountId,
          );
        },
      );
      _deployment!.addListener(_deploymentChanged);
    }
    _pages = [
      widget.rainPage,
      widget.githubPage ?? GithubPage(controller: _github),
      widget.cloudPage ?? CloudPage(controller: _cloud!),
      widget.deploymentPage ??
          (_deployment == null
              ? const SizedBox.shrink()
              : DeploymentPage(controller: _deployment!)),
    ];
  }

  void _deploymentChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _deployment?.removeListener(_deploymentChanged);
    _deployment?.dispose();
    _github?.dispose();
    _cloud?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _deployment?.busy != true,
    child: Scaffold(
      body: IndexedStack(index: _selected, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selected,
        onDestinationSelected: _deployment?.busy == true
            ? null
            : (value) => setState(() => _selected = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.water_drop_outlined),
            label: '雨课堂',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_tree_outlined),
            label: 'GitHub',
          ),
          NavigationDestination(
            icon: Icon(Icons.cloud_outlined),
            label: 'Cloudflare',
          ),
          NavigationDestination(
            icon: Icon(Icons.rocket_launch_outlined),
            label: '部署验证',
          ),
        ],
      ),
    ),
  );
}
