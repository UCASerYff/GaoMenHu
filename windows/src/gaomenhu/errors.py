class AppError(Exception):
    def __init__(self, message, code="error"):
        super().__init__(message)
        self.message = message
        self.code = code

    def __str__(self):
        return self.message


class RecoveryError(AppError):
    def __init__(self, message="资料缺失、不可读、版本不受支持或事务未完成；请保留现有文件并恢复安全副本。"):
        super().__init__(message, code="recovery")
