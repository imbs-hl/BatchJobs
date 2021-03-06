doJob = function(reg, ids, multiple.result.files, staged, disable.mail, first, last, array.id) {
  saveOne = function(result, name) {
    fn = getResultFilePath(reg, job$id, name)
    message("Writing result file: ", fn)
    save2(file = fn, result = result)
  }

  # Get the conf
  conf = loadConf(reg)

  # Say hi.
  messagef("%s: Starting job on node %s.", Sys.time(), Sys.info()["nodename"])
  messagef("Auto-mailer settings: start=%s, done=%s, error=%s.", conf$mail.start, conf$mail.done, conf$mail.error)

  # We need to see all warnings immediatly
  if (conf$cluster.functions$name != "Testing")
    options(warning.length = 8170L, warn = 1L + conf$raise.warnings)

  # Go to the work.dir
  wd = switchWd(reg)
  on.exit({
    wd$reset()
    message("Memory usage according to gc:")
    print(gc())
  })

  if (!is.na(array.id)) {
    # FIXME better send error to database here, we don't see those errors on the master :(
    array.id = asInt(as.integer(array.id), lower = 1L, upper = length(ids))
    messagef("Processing array id %s", array.id)
    ids = ids[array.id]
  }

  n = length(ids)
  results = character(n)
  error = logical(n)
  mail.extra.msg = ""
  cache = makeFileCache(use.cache = n > 1L)

  # notify status
  sendMail(reg, ids, results, "", disable.mail, condition = "start", first, last)

  # create buffer of started messages
  msg.buf = buffer(capacity = 2L * n)
  next.flush = 0L
  if (staged) {
    fn = getJobFile(reg, first)
    messagef("Loading jobs from file '%s'", fn)
    jobs = readRDS(fn)
  } else {
    jobs = getJobs(reg, ids, check.ids = FALSE)
  }

  for (i in seq_len(n)) {
    job = jobs[[as.character(ids[i])]]
    messagef("########## Executing jid=%s ##########", job$id)
    started = Sys.time()
    msg.buf$push(dbMakeMessageStarted(reg, ids[i], time = as.integer(started)))
    messagef("Timestamp: %s" , started)
    print(job)

    if (now() > next.flush) {
      if (dbSendMessages(reg, msg.buf$get(), staged = staged))
        msg.buf$clear()
      next.flush = now() + as.integer(runif(1L, 1200L, 24001L))
    }

    message("Setting seed: ", job$seed)
    seed = seeder(reg, job$seed)
    if (conf$measure.mem)
      gc(reset = TRUE)

    result = try(applyJobFunction(reg, job, cache), silent = TRUE)

    mem.used = if (conf$measure.mem) sum(gc()[, 6L]) else -1
    seed$reset()

    catf("Result:")
    print(str(result, max.level = 1L, list.len = 5L))

    error[i] = is.error(result)
    if (error[i]) {
      results[i] = as.character(result)
    } else if (multiple.result.files) {
      if (!is.list(result)) {
        results[i] = "multiple.result.files is TRUE, but your algorithm did not return a list!"
        error[i] = TRUE
      } else if (!isProperlyNamed(result)) {
        results[i] = "multiple.result.files is TRUE, but some the returned lists is not fully, distinctly named!"
        error[i] = TRUE
      }
    }

    if (error[i]) {
      msg.buf$push(dbMakeMessageError(reg, job$id, err.msg = results[i], memory = mem.used))
      message("Error occurred: ", results[i])
    } else {
      results[i] = paste0(capture.output(str(result)), collapse = "\n")
      msg.buf$push(dbMakeMessageDone(reg, job$id, memory = mem.used))

      if (multiple.result.files) {
        Map(saveOne, result = result, name = names(result))
      } else {
        saveOne(result, NA_character_)
      }
    }
  }

  # try to flush the remaining msgs at the end
  for (i in seq_len(10L)) {
    if (dbSendMessages(reg, msg.buf$get(), staged = staged)) {
      msg.buf$clear()
      break
    }
    Sys.sleep(round(runif(1L, 30, 120)))
  }

  # check if there are still remaining messages
  if (!msg.buf$empty()) {
    mail.extra.msg = paste("Some DB messages could not be flushed.",
                           "This indicates some DB problem or too much communication with the DB.",
                           "Everything should still be ok, you only might have to resubmit some jobs as they are not recorded as 'done'.",
                           sep = "\n")
    warningf(mail.extra.msg)
  }

  sendMail(reg, ids, results, mail.extra.msg, disable.mail, condition = ifelse(any(error), "error", "done"), first, last)
  messagef("%s: All done.", Sys.time())
  return(!any(error))
}
