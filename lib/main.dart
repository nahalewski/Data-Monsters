import 'package:flutter/material.dart';

void main() {
  runApp(const JunkRemovalApp());
}

class JunkRemovalApp extends StatelessWidget {
  const JunkRemovalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'J.P Junk Removal Services',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF59F2A),
          brightness: Brightness.light,
        ),
        fontFamily: 'Arial',
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const services = [
    'Furniture',
    'Household junk',
    'Clothing, toys, electronics, and more',
    'Appliances',
    'Small bulk items',
    'Random items',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF7E6),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              const _HeroSection(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Column(
                    children: [
                      Text(
                        'Fast, friendly junk removal when you need space back.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: const Color(0xFF231F20),
                            ),
                      ),
                      const SizedBox(height: 24),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final isWide = constraints.maxWidth > 760;
                          final cards = [
                            const _InfoCard(
                              icon: Icons.local_shipping_outlined,
                              title: 'Truck Ready',
                              body: 'Need junk gone ASAP? We show up ready to haul furniture, appliances, and everyday clutter.',
                            ),
                            _ServicesCard(services: services),
                            const _InfoCard(
                              icon: Icons.handshake_outlined,
                              title: 'You Point, We Haul',
                              body: 'Simple service: show us what needs to go and we handle the lifting, loading, and cleanup.',
                            ),
                          ];

                          final paddedCards = cards
                              .map(
                                (card) => Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: card,
                                ),
                              )
                              .toList();

                          final cardsFlex = Flex(
                            direction: isWide ? Axis.horizontal : Axis.vertical,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: isWide
                                ? paddedCards.map((card) => Expanded(child: card)).toList()
                                : paddedCards,
                          );

                          // The page scrolls vertically, so a horizontal row
                          // has no height bound; IntrinsicHeight gives stretch
                          // a finite extent (and equal-height cards).
                          return isWide ? IntrinsicHeight(child: cardsFlex) : cardsFlex;
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const _CallToAction(),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroSection extends StatelessWidget {
  const _HeroSection();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      // Loosens the width constraint so the maxWidth cap below can
      // take effect and the hero stays centered on wide screens.
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFF7B54B), Color(0xFFF59F2A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 56),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 820;
              final textPanel = Column(
                      crossAxisAlignment: isWide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                      children: [
                        Text(
                          'J.P JUNK\nREMOVAL',
                          textAlign: isWide ? TextAlign.left : TextAlign.center,
                          style: Theme.of(context).textTheme.displayMedium?.copyWith(
                                fontWeight: FontWeight.w900,
                                letterSpacing: 1.2,
                                color: const Color(0xFF111111),
                                height: 0.95,
                              ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'SERVICES',
                          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 8,
                              ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'You point, we haul 💪',
                          textAlign: isWide ? TextAlign.left : TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                color: const Color(0xFF231F20),
                                fontStyle: FontStyle.italic,
                              ),
                        ),
                        const SizedBox(height: 26),
                        FilledButton.icon(
                          onPressed: () {},
                          icon: const Icon(Icons.phone),
                          label: const Text('Book a Pickup'),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF111111),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
                          ),
                        ),
                      ],
                    );

              final truckPanel = const _TruckIllustration();

              return Flex(
                direction: isWide ? Axis.horizontal : Axis.vertical,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (isWide) Expanded(flex: 6, child: textPanel) else textPanel,
                  SizedBox(width: isWide ? 32 : 0, height: isWide ? 0 : 32),
                  if (isWide) Expanded(flex: 4, child: truckPanel) else truckPanel,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TruckIllustration extends StatelessWidget {
  const _TruckIllustration();

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Image.asset(
        'assets/images/truck.webp',
        fit: BoxFit.contain,
        semanticLabel: 'Orange pickup truck loaded with moving boxes',
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 42, color: const Color(0xFFF59F2A)),
            const SizedBox(height: 18),
            Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(body, style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.45)),
          ],
        ),
      ),
    );
  }
}

class _ServicesCard extends StatelessWidget {
  const _ServicesCard({required this.services});

  final List<String> services;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: const Color(0xFF231F20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('We remove', style: Theme.of(context).textTheme.titleLarge?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            ...services.map(
              (service) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.check_circle, color: Color(0xFFF59F2A), size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text(service, style: const TextStyle(color: Colors.white, fontSize: 16))),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CallToAction extends StatelessWidget {
  const _CallToAction();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFF111111),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
      child: Column(
        children: [
          Text(
            'Ready to clear the clutter?',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          const Text(
            'Contact J.P Junk Removal Services for quick pickup and honest hauling help.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ],
      ),
    );
  }
}
