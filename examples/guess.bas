100 LET X = RND(30000)
    LET I = 0
    PRINT "I chose a number from 1-30000"
101 GOSUB 300
    LET I = I + 1
    IF N < X THEN GOTO 102
    IF N > X THEN GOTO 103
    GOTO 104
102 PRINT "Too small"
    GOTO 101
103 PRINT "Too big"
    GOTO 101
104 PRINT "Bingo!"
    PRINT "It took you", I, "guesses."
    GOTO 400

    REM N = Player guess
300 PRINT "Take a guess!"
    INPUT N
    IF N < 1 THEN GOTO 301
    IF N > 30000 THEN GOTO 302
    RETURN
301 PRINT "It should be at least 1"
    GOTO 300
302 PRINT "It should be at most 30000"
    GOTO 300

400 PRINT ""
    PRINT "Play again?"
    PRINT "0-Yes 1-No"
    INPUT A
    IF A = 0 THEN GOTO 100
    IF A = 1 THEN END
    GOTO 400

