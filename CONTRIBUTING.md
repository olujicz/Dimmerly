# Contributing to Dimmerly

Thank you for your interest in contributing to Dimmerly! This document provides guidelines and instructions for contributing.

## Code of Conduct

This project adheres to a Code of Conduct that all contributors are expected to follow. Please read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before contributing.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check the [issue tracker](https://github.com/olujicz/dimmerly/issues) to avoid duplicates.

When you create a bug report, include as many details as possible:

- **Use a clear and descriptive title**
- **Describe the exact steps to reproduce the problem**
- **Provide specific examples** (code samples, screenshots, etc.)
- **Describe the behavior you observed and what you expected**
- **Include your environment details:**
  - macOS version
  - Dimmerly version
  - Any relevant system settings

### Suggesting Features

Feature suggestions are welcome! Please:

- **Use a clear and descriptive title**
- **Provide a detailed description** of the suggested feature
- **Explain why this feature would be useful** to most Dimmerly users
- **List any alternative solutions** you've considered

### Pull Requests

1. **Fork the repository** and create your branch from `main`
2. **Follow the coding style** of the project
3. **Write tests** for new functionality
4. **Update documentation** as needed
5. **Ensure all tests pass** before submitting

## Development Setup

### Prerequisites

- macOS 13.0 (Ventura) or later
- Xcode 15.0 or later
- Swift 5.9 or later

### Building from Source

1. Clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/dimmerly.git
   cd dimmerly
   ```

2. Open the project:
   ```bash
   open Dimmerly.xcodeproj
   ```

3. Build and run:
   - Select the Dimmerly scheme
   - Press ⌘R to build and run

### Running Tests

```bash
# Run all tests
xcodebuild test -scheme Dimmerly -destination 'platform=macOS'

# Or use Xcode's Test Navigator (⌘6)
```

## Coding Standards

### Swift Style Guide

- Follow [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- Use 4 spaces for indentation (no tabs)
- Limit lines to 120 characters when practical
- Use meaningful variable and function names
- Write documentation comments (`///`) for public APIs

### Code Organization

- Place new models in `Dimmerly/Models/`
- Place new views in `Dimmerly/Views/`
- Place new utilities in `Dimmerly/Utilities/`
- Add tests in `DimmerlyTests/`

### Documentation

- Add file header comments to new files
- Document public functions and types with `///` comments
- Include code examples for complex functionality
- Update README.md if adding user-facing features

### Testing

- Write unit tests for new functionality
- Ensure existing tests still pass
- Aim for >80% code coverage on business logic
- Don't test UI components (focus on models and controllers)

## Commit Messages

- Use the imperative mood ("add feature" not "added feature")
- Start with a lowercase letter
- Keep the first line under 72 characters
- Add detailed description after a blank line if needed
- Reference issues and pull requests when relevant

Example:
```
add keyboard shortcut customization for quit action

Allows users to customize the quit keyboard shortcut in settings.
Implements validation to prevent conflicts with system shortcuts.

Fixes #123
```

## Pull Request Process

1. **Update documentation** for any changed functionality
2. **Add tests** for new features
3. **Run the test suite** and ensure all tests pass
4. **Update CHANGELOG.md** with your changes
5. **Request review** from maintainers

### PR Checklist

- [ ] Tests pass locally
- [ ] Code follows the project's style guidelines
- [ ] Documentation updated
- [ ] CHANGELOG.md updated (if applicable)
- [ ] No merge conflicts with main branch
- [ ] Commit messages are clear and descriptive

## Questions?

Feel free to ask questions by:

- Opening an [issue](https://github.com/olujicz/dimmerly/issues)
- Starting a [discussion](https://github.com/olujicz/dimmerly/discussions)

## License

By contributing to Dimmerly, you agree that your contributions will be licensed under the MIT License.

Thank you for contributing! 🎉
