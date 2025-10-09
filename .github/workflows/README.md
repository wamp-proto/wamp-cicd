we must symlink because when referencing in a using GitHub actions workflow

```
uses: wamp-proto/wamp-cicd/.github/workflows/identifiers.yml@main
```

the workflow MUST reside in `.github/workflows` (yes, wtf!), otherwise you get:

*invalid value workflow reference: references to workflows must be rooted in '.github/workflows'*
