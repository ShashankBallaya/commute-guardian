# commute_guardian

A new Flutter project.

## Building

```
flutter pub get
flutter run
```

Crash reporting (Sentry) and analytics (Aptabase) need keys that are **not** in
this repository. Without them the app runs normally with both switched off,
which is what a clone gets. To enable them, copy `secrets.example.json` to
`secrets.json`, paste the keys in, and add
`--dart-define-from-file=secrets.json` to any `run` or `build`. See
[docs/sentry.md](docs/sentry.md) and [docs/analytics.md](docs/analytics.md).

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
