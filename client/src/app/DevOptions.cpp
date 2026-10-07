#include "app/DevOptions.h"

DevOptions DevOptions::parse(const QStringList &args)
{
    DevOptions o;
#ifdef SUPERBD_DEV_TOOLS
    o.enabled = true;
    for (int i = 1; i + 1 < args.size(); ++i) {
        const QString &key = args.at(i);
        const QString &value = args.at(i + 1);
        if (key == QLatin1String("--dev-as"))                o.devAs = value;
        else if (key == QLatin1String("--dev-user"))         o.devUser = value;
        else if (key == QLatin1String("--open"))             o.openForm = value;
        else if (key == QLatin1String("--card"))             o.card = value;
        else if (key == QLatin1String("--arg")) {
            const QString k = value.section(QLatin1Char('='), 0, 0);
            const QString v = value.section(QLatin1Char('='), 1);
            if (v == QLatin1String("true") || v == QLatin1String("false"))
                o.args.insert(k, v == QLatin1String("true"));
            else
                o.args.insert(k, v);
        }
        else if (key == QLatin1String("--screenshot"))       o.screenshot = value;
        else if (key == QLatin1String("--screenshot-login")) o.screenshotLogin = value;
        else if (key == QLatin1String("--login-error"))      o.loginError = value;
    }
#else
    Q_UNUSED(args);
#endif
    return o;
}
