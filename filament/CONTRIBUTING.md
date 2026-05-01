# Contributing to Filament

Thank you for your interest in contributing to Filament! This document provides guidelines and instructions for contributing to the project.

## Development Setup

1. Ensure you have Elixir 1.17+ and OTP 26+ installed
2. Clone the repository
3. Install dependencies:
   ```bash
   mix deps.get
   ```

## Running Tests

Run the full test suite:

```bash
mix test
```

## Code Quality Checks

This project uses several tools to maintain code quality:

### Compile with Warnings as Errors

```bash
mix compile --warnings-as-errors
```

### Credo (Linter)

Run the linter in strict mode:

```bash
mix credo --strict
```

### Dialyzer (Static Analysis)

Run Dialyzer to check for type errors:

```bash
mix dialyzer
```

Note: The first run may take a while as it builds the PLT cache.

## Opening a Pull Request

1. Fork the repository
2. Create a feature branch from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. Make your changes and ensure all tests pass
4. Run the quality checks (compile, credo, dialyzer)
5. Commit your changes with a clear commit message referencing the ticket
6. Push to your fork and open a pull request

### Pull Request Guidelines

- Include a clear description of the changes
- Reference any related issues or tickets
- Ensure CI passes
- Squash commits if needed

## Documentation

To generate and view documentation locally:

```bash
mix docs
open doc/index.html
```
