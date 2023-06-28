# git4jamfpro #

A tool designed for CI/CD pipelines that uploads the most recently changed scripts and extension attributes in source control to a Jamf Pro server(s).

This is a rewrite of the great (but very aged) [git2jss](https://github.com/badstreff/git2jss) python library written by [badstreff](https://github.com/badstreff).

### What are the benefits of git4jamfpro? ###

* Designed and packaged to be be ran in a CI/CD pipeline. We even include sample pipeline config files for CircleCI, Bitbucket, and GitHub to get you up and running quickly.
* No python dependency; git4jamfpro is written in bash.
* Uses modern Bearer Token authentication with Jamf Pro.
* Allows you to download all scripts and extension attributes (EAs) in parallel from a Jamf Pro server.
* You can update (or create) scripts/EAs locally, commit the changes to your repository, and the changed scripts/EAs are pushed to Jamf Pro automatically by your pipeline. This ensures that script/EA changes are always tracked in source control.
* When a script/EA is updated, a backup can be left as an artifact in your CI/CD pipeline.

### Setting up git4jamfpro ###
1. Fork your own copy of the repository.
2. Clone the repository locally:

```
git clone git@github.com:YOUR_ORGANIZATION/git4jamfpro.git (or equivalent)
```

3. Traverse into the repository:

```
cd git4jamfpro
```

4. Download your scripts/EAs:

```
./git4jamfpro --url <YOUR_JAMF_PRO_SERVER> \
    --username <API_USER> \
    --password <API_PASS> \
    --download-scripts \
    --download-eas
```

5. Commit the repository populated with scripts/EAs to your source control:

```
git add .
git commit -m "initial commit with scripts/EAs"
```

6. Configure your pipeline (see the [Wiki](https://github.com/alectrona/git4jamfpro/wiki) for [CircleCI](https://github.com/alectrona/git4jamfpro/wiki/Deploy-in-CircleCI), [Bitbucket](https://github.com/alectrona/git4jamfpro/wiki/Deploy-in-Bitbucket), and [GitHub](https://github.com/alectrona/git4jamfpro/wiki/Deploy-in-GitHub) setup).
7. Make sure you pull the latest changes from your repository:

```
git pull
```

8. Now you can make changes to your scripts locally, push those changes to source control, and watch your pipeline automatically update Jamf Pro 🤯.