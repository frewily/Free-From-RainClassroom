import os
import smtplib
import ssl
from email.message import EmailMessage


SMTP_KEYS = ("EMAIL_HOST", "EMAIL_USER", "EMAIL_PASS", "TO_EMAIL")


def email_notice(subject: str, content: str):
    """Keep the legacy exam notification entry point disabled."""
    return False


def email_is_configured():
    present = [bool(os.getenv(key, "")) for key in SMTP_KEYS]
    if any(present) and not all(present):
        print("邮件配置不完整，跳过通知；请检查 EMAIL_HOST/EMAIL_USER/EMAIL_PASS/TO_EMAIL", flush=True)
    return all(present)


def send_email(subject: str, content: str, *, attachment_text=None,
               attachment_name="listening-log.txt"):
    """Send an optional email without exposing SMTP credentials in diagnostics."""
    if not email_is_configured():
        return False
    settings = {key: os.getenv(key, "") for key in SMTP_KEYS}

    try:
        port = int(os.getenv("EMAIL_PORT") or "465")
        security = (os.getenv("EMAIL_SECURITY") or "ssl").lower()
        if not 1 <= port <= 65535 or security not in ("ssl", "starttls"):
            raise ValueError("Invalid SMTP configuration")
        message = EmailMessage()
        message["Subject"] = subject
        message["From"] = settings["EMAIL_USER"]
        message["To"] = settings["TO_EMAIL"]
        message.set_content(content)
        if attachment_text is not None:
            message.add_attachment(attachment_text, subtype="plain", filename=attachment_name)
        context = ssl.create_default_context()
        if security == "ssl":
            server = smtplib.SMTP_SSL(settings["EMAIL_HOST"], port, timeout=10, context=context)
        else:
            server = smtplib.SMTP(settings["EMAIL_HOST"], port, timeout=10)
        with server as connection:
            if security == "starttls":
                connection.ehlo()
                connection.starttls(context=context)
                connection.ehlo()
            connection.login(settings["EMAIL_USER"], settings["EMAIL_PASS"])
            connection.send_message(message)
        print("邮件通知已交给 SMTP 服务器", flush=True)
        return True
    except Exception as error:
        # SMTP responses and exception messages may echo addresses or credentials.
        print(f"邮件通知失败：{type(error).__name__}；监听继续", flush=True)
        return False
