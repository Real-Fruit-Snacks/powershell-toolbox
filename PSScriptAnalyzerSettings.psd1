@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # These are interactive console scripts. Colored status lines are the point,
        # and every one goes through Write-Ink, which honors NO_COLOR.
        'PSAvoidUsingWriteHost'
    )
}
