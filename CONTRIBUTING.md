# Contributing to Azure Private DNS Lab

Thank you for your interest in contributing to this project! We welcome contributions from the community.

## How to Contribute

### Reporting Issues

- Use GitHub Issues to report bugs or suggest features
- Check existing issues before creating a new one
- Include as much detail as possible (Azure region, error messages, screenshots)

### Submitting Changes

1. **Fork the repository** and create your branch from `main`
2. **Make your changes** and test the deployment in your own Azure subscription
3. **Update documentation** if you've changed parameters or added features
4. **Submit a pull request** with a clear description of your changes

### Code Guidelines

- **Bicep files**: Follow [Bicep best practices](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/best-practices)
- **PowerShell scripts**: Use approved verbs and include comment-based help
- **Naming conventions**: Use consistent, descriptive names for resources and parameters

### Testing Your Changes

Before submitting a PR, please verify:

1. The deployment completes successfully with `az deployment sub create`
2. All resources are created in the correct resource groups
3. DNS resolution works as expected (on-premises to Azure and Azure to on-premises)
4. The "Deploy to Azure" button works (if you modified `azuredeploy.json`)

### Updating the ARM Template

If you modify `main.bicep`, regenerate the ARM template:

```bash
az bicep build --file main.bicep --outfile azuredeploy.json
```

## Code of Conduct

Be respectful and constructive in all interactions. We're all here to learn and build together.

## Questions?

Open an issue with the `question` label and we'll do our best to help.
